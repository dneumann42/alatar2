-- Preview Aseprite files (.ase / .aseprite) as images: ellipse renders
-- frame 0 through the engine's own loader and writes a PNG cache file
-- under /tmp, which then goes up with the terminal's image protocol.
--
-- Finds the ellipse binary on $PATH or in the usual install locations,
-- so a GUI session without ~/.local/bin still previews. Without ellipse
-- anywhere, the preview says so instead of dumping bytes.

local M = {}

local DIR = "/tmp/ellipse-aseprite"

-- The ellipse binary, found once and remembered. yazi inherits the
-- environment of whatever launched it -- a GUI session often lacks
-- ~/.local/bin -- so a plain PATH hit is tried first, then the usual
-- install spots. `ellipse image --help` answers without touching SDL,
-- which makes it a cheap probe.
function M.ellipse()
	if M.ellipse_path == nil then
		local home = os.getenv("HOME") or ""
		M.ellipse_path = false
		for _, cand in ipairs({
			"ellipse",
			home .. "/.local/bin/ellipse",
			"/usr/local/bin/ellipse",
			"/usr/bin/ellipse",
		}) do
			local status = Command(cand)
				:arg({ "image", "--help" })
				:stdout(Command.NULL)
				:stderr(Command.NULL)
				:status()
			if status and status.success then
				M.ellipse_path = cand
				break
			end
		end
	end
	return M.ellipse_path or nil
end

function M.cache(job)
	local key = string.format("aseprite//%s//%.10f", job.file.url, job.file.cha.mtime)
	return Url(DIR .. "/" .. ya.hash(key) .. ".png")
end

-- Render the sprite to the cache path, returning nil or an Error.
function M.export(job, cache)
	local ellipse = M.ellipse()
	if not ellipse then
		return Err("`ellipse` not found -- install it with `make install` in the ellipse repository")
	end

	Command("mkdir"):arg({ "-p", DIR }):status()

	local output, err = Command(ellipse)
		:arg({
			"image", "export", tostring(job.file.url),
			"--format", "png",
			"--output", tostring(cache),
		})
		:output()

	if not output then
		return Err("Failed to start `%s`, error: %s", ellipse, err)
	elseif not output.status.success then
		return Err("Failed to render the sprite, stderr: %s", output.stderr)
	end
end

function M:peek(job)
	local cache = M.cache(job)
	if not fs.cha(cache) then
		local err = M.export(job, cache)
		if err then
			return ya.preview_widget(job, err)
		end
	end

	local _, err = ya.image_show(cache, job.area)
	ya.preview_widget(job, err)
end

function M:seek() end

function M:preload(job)
	local cache = M.cache(job)
	if fs.cha(cache) then
		return true
	end

	local err = M.export(job, cache)
	if err then
		return true, err
	end
	return true
end

return M
