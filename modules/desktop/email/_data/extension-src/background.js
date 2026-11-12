'use strict';

/* Diagnostics build: every branch announces itself through a mako
 * notification (visible without opening about:debugging), then attempts the
 * privileged provision() call and reports the outcome the same way. */

function notify(title, message) {
  try {
    browser.notifications.create({
      type: 'basic',
      title: `provision: ${title}`,
      message,
    });
  } catch (e) { /* ignore */ }
}

(async () => {
  // Uncaught here lands on stderr = our observable channel.
  await browser.notifications.create({
    type: 'basic',
    title: 'provision: load',
    message: 'background script is running',
  });
  const result = await browser.ProtonBridge.provision();
  await browser.notifications.create({
    type: 'basic',
    title: 'provision: result',
    message: JSON.stringify(result),
  });
})();
