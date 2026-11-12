'use strict';

/*
 * Experiment API (addon_process scope), pattern copied from Thunderbird's own
 * built-in thundermail/MailAccounts add-on (the shipped user of
 * CreateInBackend.createAccountInBackend - extracted from this exact build to
 * confirm the call shape and enum spellings, TB 159). Outcome is also written
 * to the char pref mail.protonbridge.provision.last so it lands in prefs.js
 * on shutdown and `alatar install email` can read it back.
 */

(function (exports) {
  // ExtensionCommon is needed at file-evaluation time (the API class extends
  // it); the heavy mail modules import lazily inside the function, so a
  // wrong resource URI surfaces as a readable message, not a generic
  // "unexpected error" from failed sandbox evaluation.
  var { ExtensionCommon } = ChromeUtils.importESModule(
    'resource://gre/modules/ExtensionCommon.sys.mjs'
  );

  function configPath() {
    const env = Cc['@mozilla.org/process/environment;1'].getService(
      Ci.nsIEnvironment
    );
    const configHome = env.get('XDG_CONFIG_HOME') || env.get('HOME') + '/.config';
    return configHome + '/alatar/email.json';
  }

  function readFileSync(path) {
    // The experiment sandbox refuses resource://gre/modules/IOUtils;
    // nsIFile + converter stream is the dependable chrome-side read.
    const f = Cc['@mozilla.org/file/local;1'].createInstance(Ci.nsIFile);
    f.initWithPath(path);
    const fin = Cc['@mozilla.org/network/file-input-stream;1'].createInstance(
      Ci.nsIFileInputStream
    );
    fin.init(f, 0x01 /*_RDONLY*/, 0, 0);
    const cin = Cc['@mozilla.org/intl/converter-input-stream;1'].createInstance(
      Ci.nsIConverterInputStream
    );
    cin.init(fin, 'UTF-8', 0, Ci.nsIConverterInputStream.DEFAULT_REPLACEMENT_CHARACTER);
    const out = {};
    cin.readString(0xffffffff, out);
    cin.close();
    return out.value;
  }

  function snapshot(MailServices) {
    try {
      const accts = Array.from(MailServices.accounts.accounts).map(a => ({
        key: a.key,
        incoming: a.incomingServer ? `${a.incomingServer.type}:${a.incomingServer.hostname}:${a.incomingServer.username}` : null,
      }));
      return JSON.stringify(accts);
    } catch (e) {
      return `snapshot failed: ${e}`;
    }
  }

  async function doProvision() {
    var { CreateInBackend } = ChromeUtils.importESModule(
      'resource:///modules/accountcreation/CreateInBackend.sys.mjs'
    );
    var { AccountConfig } = ChromeUtils.importESModule(
      'resource:///modules/accountcreation/AccountConfig.sys.mjs'
    );
    var { MailServices } = ChromeUtils.importESModule(
      'resource:///modules/MailServices.sys.mjs'
    );
    const path = configPath();
    let cfg;
    try {
      cfg = JSON.parse(readFileSync(path));
    } catch (e) {
      return { success: false, message: `cannot read ${path}: ${e}` };
    }
    const email = cfg.proton_email;
    if (!email) {
      return { success: false, message: `${path} lacks proton_email` };
    }

    let found = null;
    try {
      const s = MailServices.accounts.findServer(email, '127.0.0.1', 'imap');
      found = `${s.type}:${s.hostname}:${s.username} exists at startup, accounts=${snapshot(MailServices)}`;
    } catch {
      /* findServer throws when the account is not there yet */
    }
    if (found) {
      return { success: true, alreadyExists: true, note: found };
    }

    const config = new AccountConfig();

    // Proton Mail Bridge speaks IMAP-over-TLS / SMTP-STARTTLS on localhost;
    // the client password is the Bridge's own generated one, typed into
    // Thunderbird once (that is the auth step) and stored by the password
    // manager from then on.
    config.incoming.type = 'imap';
    config.incoming.hostname = '127.0.0.1';
    config.incoming.port = 1143;
    config.incoming.username = email;
    config.incoming.password = '';
    config.incoming.socketType = Ci.nsMsgSocketType.SSL;
    config.incoming.auth = Ci.nsMsgAuthMethod.passwordCleartext;

    config.outgoing.type = 'smtp';
    config.outgoing.hostname = '127.0.0.1';
    config.outgoing.port = 1025;
    config.outgoing.username = email;
    config.outgoing.password = '';
    config.outgoing.socketType = Ci.nsMsgSocketType.alwaysSTARTTLS;
    config.outgoing.auth = Ci.nsMsgAuthMethod.passwordCleartext;
    config.outgoing.addThisServer = true;

    config.identity.realname = cfg.realname || email;
    config.identity.emailAddress = email;
    config.displayName = 'Proton Mail';
    config.rememberPassword = true;

    await CreateInBackend.createAccountInBackend(config);
    return { success: true, alreadyExists: false, note: `created; accounts=${snapshot(MailServices)}` };
  }

  class ProtonBridge extends ExtensionCommon.ExtensionAPI {
    getAPI(_context) {
      return {
        ProtonBridge: {
          async provision() {
            let result;
            try {
              result = await doProvision();
            } catch (e) {
              result = { success: false, message: `${e} | ${(e.stack || '').split('\n')[1] || ''}` };
            }
            try {
              // pre-write the breadcrumb so even a mid-create crash is visible
              Services.prefs.setCharPref(
                'mail.protonbridge.provision.steps',
                `${new Date().toISOString()} ${JSON.stringify(result)}`
              );
            } catch { /* ignore */ }
            try {
              Services.prefs.setCharPref(
                'mail.protonbridge.provision.last',
                JSON.stringify({ ...result, t: new Date().toISOString() })
              );
            } catch {
              /* breadcrumb is best-effort */
            }
            return result;
          },
        },
      };
    }
  }

  exports.ProtonBridge = ProtonBridge;
})(this);
