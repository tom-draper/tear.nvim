-- tear.nvim - Frictionless note-taking for Neovim

local M = {}
local api = vim.api
local fn = vim.fn

-- Default configuration
M.config = {
	notes = {
		path = vim.fn.expand("~/notes/tear"),
		extension = ".md",
		filename_strategy = "timestamp", -- "timestamp" or "title"
		datetime_format = "%Y-%m-%d-%H-%M-%S",
	},
	metadata = {
		index_file = ".tear_metadata.json",
		auto_persist = true,
	},
	ui = {
		enable_hashtag_display = true,
	},
}

-- Metadata store (in-memory cache)
local metadata_cache = {}

-- Utility: Create directory if it doesn't exist
local function ensure_directory(path)
	if fn.isdirectory(path) == 0 then
		fn.mkdir(path, "p")
	end
end

-- Utility: Generate filename from content
local function generate_filename_from_content(lines)
	local first_line = lines[1] or ""
	-- Remove markdown headers, trim whitespace
	first_line = first_line:gsub("^#+%s*", ""):gsub("^%s*(.-)%s*$", "%1")

	if first_line == "" then
		return os.date(M.config.notes.datetime_format)
	end

	-- Convert to lowercase, replace spaces/special chars with hyphens
	local filename = first_line:lower()
		:gsub("[%s]+", "-")
		:gsub("[^%w%-]", "")
		:sub(1, 50) -- Limit length

	return filename .. "-" .. os.date("%H%M%S")
end

-- Extract hashtags from content
local function extract_hashtags(lines)
	local tags = {}
	local tag_set = {}

	for _, line in ipairs(lines) do
		for tag in line:gmatch("#([%w_%-]+)") do
			if not tag_set[tag] then
				table.insert(tags, tag)
				tag_set[tag] = true
			end
		end
	end

	return tags
end

-- Extract keywords (simple implementation)
local function extract_keywords(lines)
	local content = table.concat(lines, " ")
	-- Remove hashtags, markdown syntax, and common words
	content = content:gsub("#%w+", "")
		:gsub("[#*_`]", "")
		:lower()

	local words = {}
	local word_freq = {}
	local common_words = {
		["the"] = true, ["a"] = true, ["an"] = true, ["and"] = true,
		["or"] = true, ["but"] = true, ["in"] = true, ["on"] = true,
		["at"] = true, ["to"] = true, ["for"] = true, ["of"] = true,
		["with"] = true, ["by"] = true, ["from"] = true, ["is"] = true,
		["was"] = true, ["are"] = true, ["were"] = true, ["be"] = true,
	}

	for word in content:gmatch("%w+") do
		if #word > 3 and not common_words[word] then
			word_freq[word] = (word_freq[word] or 0) + 1
		end
	end

	-- Get top keywords
	local sorted_words = {}
	for word, freq in pairs(word_freq) do
		table.insert(sorted_words, {word = word, freq = freq})
	end
	table.sort(sorted_words, function(a, b) return a.freq > b.freq end)

	for i = 1, math.min(10, #sorted_words) do
		table.insert(words, sorted_words[i].word)
	end

	return words
end

-- Load metadata from disk
local function load_metadata()
	local metadata_path = M.config.notes.path .. "/" .. M.config.metadata.index_file
	local file = io.open(metadata_path, "r")

	if not file then
		return {}
	end

	local content = file:read("*all")
	file:close()

	local ok, data = pcall(vim.json.decode, content)
	return ok and data or {}
end

-- Save metadata to disk
local function save_metadata()
	ensure_directory(M.config.notes.path)
	local metadata_path = M.config.notes.path .. "/" .. M.config.metadata.index_file
	local file = io.open(metadata_path, "w")

	if not file then
		vim.notify("Failed to save metadata", vim.log.levels.ERROR)
		return
	end

	file:write(vim.json.encode(metadata_cache))
	file:close()
end

-- Update metadata for a file
local function update_metadata(filepath, lines)
	local filename = fn.fnamemodify(filepath, ":t")
	local tags = extract_hashtags(lines)
	local keywords = extract_keywords(lines)

	metadata_cache[filename] = {
		created = metadata_cache[filename] and metadata_cache[filename].created or os.time(),
		modified = os.time(),
		tags = tags,
		keywords = keywords,
		filepath = filepath,
	}

	if M.config.metadata.auto_persist then
		save_metadata()
	end
end

-- Create a new tear note
function M.tear()
	-- Check if there's already an unsaved tear note open
	for _, bufnr in ipairs(api.nvim_list_bufs()) do
		if api.nvim_buf_is_loaded(bufnr) then
			local bufname = api.nvim_buf_get_name(bufnr)
			local buftype = api.nvim_buf_get_option(bufnr, "buftype")

			if buftype == "acwrite" and bufname:match("%[Tear Note") then
				-- Found an existing unsaved tear note, switch to it
				api.nvim_set_current_buf(bufnr)
				vim.notify("Switched to existing unsaved note", vim.log.levels.INFO)
				return
			end
		end
	end

	local bufnr = api.nvim_create_buf(false, true)
	api.nvim_set_current_buf(bufnr)

	-- Set buffer options
	api.nvim_buf_set_option(bufnr, "filetype", "markdown")
	api.nvim_buf_set_option(bufnr, "buftype", "acwrite")
	api.nvim_buf_set_option(bufnr, "bufhidden", "hide")

	-- Set a placeholder name so :w works
	api.nvim_buf_set_name(bufnr, "[Tear Note]")

	-- Create autocommand to handle saving
	local aug = api.nvim_create_augroup("TearNote_" .. bufnr, {clear = true})
	api.nvim_create_autocmd("BufWriteCmd", {
		buffer = bufnr,
		group = aug,
		callback = function()
			local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)

			-- Generate filename
			local filename

			-- First check if a custom name was set with :TearName
			local ok, custom_name = pcall(api.nvim_buf_get_var, bufnr, "tear_unsaved_name")

			if ok and custom_name then
				-- Use the custom name set by :TearName
				filename = custom_name
				if not filename:match(vim.pesc(M.config.notes.extension) .. "$") then
					filename = filename .. M.config.notes.extension
				end
			elseif M.config.notes.filename_strategy == "title" then
				filename = generate_filename_from_content(lines) .. M.config.notes.extension
			else
				filename = os.date(M.config.notes.datetime_format) .. M.config.notes.extension
			end

			-- Save file
			ensure_directory(M.config.notes.path)
			local filepath = M.config.notes.path .. "/" .. filename

			-- Check if file already exists (in case of very fast saves)
			local counter = 1
			while fn.filereadable(filepath) == 1 do
				local base = filename:match("(.+)%..+$") or filename
				local ext = filename:match("%.(.+)$") or ""
				filepath = M.config.notes.path .. "/" .. base .. "-" .. counter .. "." .. ext
				counter = counter + 1
			end

			local file = io.open(filepath, "w")

			if not file then
				vim.notify("Failed to save note", vim.log.levels.ERROR)
				return
			end

			file:write(table.concat(lines, "\n"))
			file:close()

			-- Update metadata
			update_metadata(filepath, lines)

			-- Clear the custom name variable since it's now saved
			if ok and custom_name then
				pcall(api.nvim_buf_del_var, bufnr, "tear_unsaved_name")
			end

			-- Update buffer to point to real file
			api.nvim_buf_set_option(bufnr, "buftype", "")
			api.nvim_buf_set_name(bufnr, filepath)
			api.nvim_buf_set_option(bufnr, "modified", false)

			vim.notify("Note saved: " .. fn.fnamemodify(filepath, ":t"), vim.log.levels.INFO)
		end,
	})

	vim.notify("New note", vim.log.levels.INFO)
end

-- Show recent notes
function M.recent(count)
	count = count or 10

	-- Get all note files
	local notes = {}
	for filename, meta in pairs(metadata_cache) do
		table.insert(notes, {
			filename = filename,
			modified = meta.modified,
			tags = meta.tags,
		})
	end

	-- Sort by modified time
	table.sort(notes, function(a, b) return a.modified > b.modified end)

	-- Display in a floating window
	local lines = {"Recent Notes", ""}
	for i = 1, math.min(count, #notes) do
		local note = notes[i]
		local date = os.date("%Y-%m-%d %H:%M", note.modified)
		local tags_str = #note.tags > 0 and " [#" .. table.concat(note.tags, " #") .. "]" or ""
		table.insert(lines, string.format("%d. %s - %s%s", i, note.filename, date, tags_str))
	end

	if #notes == 0 then
		table.insert(lines, "No notes found. Create one with :Tear")
	end

	-- Create floating window
	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	api.nvim_buf_set_option(buf, "modifiable", false)
	api.nvim_buf_set_option(buf, "filetype", "markdown")

	local width = 80
	local height = math.min(#lines + 2, 20)
	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = (vim.o.columns - width) / 2,
		row = (vim.o.lines - height) / 2,
		style = "minimal",
		border = "rounded",
	})

	-- Close on 'q' or <Esc>
	api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", {noremap = true, silent = true})
	api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", {noremap = true, silent = true})

	-- Open note on <Enter>
	api.nvim_buf_set_keymap(buf, "n", "<CR>", "", {
		noremap = true,
		silent = true,
		callback = function()
			local line = api.nvim_get_current_line()
			local idx = line:match("^(%d+)%.")
			if idx then
				idx = tonumber(idx)
				local note = notes[idx]
				if note then
					local filepath = M.config.notes.path .. "/" .. note.filename
					api.nvim_command("close")
					api.nvim_command("edit " .. filepath)
				end
			end
		end,
	})
end

-- Search notes by tags or keywords
function M.search(query)
	if not query or query == "" then
		vim.ui.input({prompt = "Search (tag or keyword): "}, function(input)
			if input then
				M.search(input)
			end
		end)
		return
	end

	query = query:lower()
	local results = {}

	for filename, meta in pairs(metadata_cache) do
		local match = false

		-- Check tags
		for _, tag in ipairs(meta.tags) do
			if tag:lower():find(query, 1, true) then
				match = true
				break
			end
		end

		-- Check keywords
		if not match then
			for _, keyword in ipairs(meta.keywords) do
				if keyword:lower():find(query, 1, true) then
					match = true
					break
				end
			end
		end

		if match then
			table.insert(results, {
				filename = filename,
				tags = meta.tags,
				modified = meta.modified,
			})
		end
	end

	-- Sort by modified time
	table.sort(results, function(a, b) return a.modified > b.modified end)

	-- Display results
	local lines = {string.format("Search Results: '%s'", query), ""}
	for i, result in ipairs(results) do
		local date = os.date("%Y-%m-%d %H:%M", result.modified)
		local tags_str = #result.tags > 0 and " [" .. table.concat(result.tags, ", ") .. "]" or ""
		table.insert(lines, string.format("%d. %s - %s%s", i, result.filename, date, tags_str))
	end

	if #results == 0 then
		table.insert(lines, string.format("No notes found matching '%s'", query))
	end

	-- Create floating window
	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	api.nvim_buf_set_option(buf, "modifiable", false)
	api.nvim_buf_set_option(buf, "filetype", "markdown")

	local width = 80
	local height = math.min(#lines + 2, 20)
	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = (vim.o.columns - width) / 2,
		row = (vim.o.lines - height) / 2,
		style = "minimal",
		border = "rounded",
	})

	api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", {noremap = true, silent = true})
	api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", {noremap = true, silent = true})

	-- Open note on <Enter>
	api.nvim_buf_set_keymap(buf, "n", "<CR>", "", {
		noremap = true,
		silent = true,
		callback = function()
			local line = api.nvim_get_current_line()
			local idx = line:match("^(%d+)%.")
			if idx then
				idx = tonumber(idx)
				local result = results[idx]
				if result then
					local filepath = M.config.notes.path .. "/" .. result.filename
					api.nvim_command("close")
					api.nvim_command("edit " .. filepath)
				end
			end
		end,
	})
end

-- Simple CLI visualization of tag connections
function M.visualize()
	-- Build tag graph
	local tag_connections = {}
	local tag_files = {}

	for filename, meta in pairs(metadata_cache) do
		for _, tag in ipairs(meta.tags) do
			tag_files[tag] = tag_files[tag] or {}
			table.insert(tag_files[tag], filename)
		end

		-- Connect tags that appear together
		for i = 1, #meta.tags do
			for j = i + 1, #meta.tags do
				local pair = meta.tags[i] .. " <-> " .. meta.tags[j]
				tag_connections[pair] = (tag_connections[pair] or 0) + 1
			end
		end
	end

	-- Generate visualization
	local lines = {"Tag Graph", "", "Tag Connections", ""}

	local sorted_connections = {}
	for pair, count in pairs(tag_connections) do
		table.insert(sorted_connections, {pair = pair, count = count})
	end
	table.sort(sorted_connections, function(a, b) return a.count > b.count end)

	for i = 1, math.min(20, #sorted_connections) do
		local conn = sorted_connections[i]
		table.insert(lines, string.format("  %s (%d notes)", conn.pair, conn.count))
	end

	table.insert(lines, "")
	table.insert(lines, "Tags by Frequency")
	table.insert(lines, "")

	local sorted_tags = {}
	for tag, files in pairs(tag_files) do
		table.insert(sorted_tags, {tag = tag, count = #files})
	end
	table.sort(sorted_tags, function(a, b) return a.count > b.count end)

	for _, item in ipairs(sorted_tags) do
		local bar = string.rep("█", math.min(item.count, 50))
		table.insert(lines, string.format("  #%-20s %3d %s", item.tag, item.count, bar))
	end

	-- Create floating window
	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	api.nvim_buf_set_option(buf, "modifiable", false)
	api.nvim_buf_set_option(buf, "filetype", "markdown")

	local width = 90
	local height = math.min(#lines + 2, vim.o.lines - 4)
	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = (vim.o.columns - width) / 2,
		row = (vim.o.lines - height) / 2,
		style = "minimal",
		border = "rounded",
	})

	api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", {noremap = true, silent = true})
	api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", {noremap = true, silent = true})
end

-- Name the current note
function M.name(new_name)
	local bufnr = api.nvim_get_current_buf()
	local current_file = api.nvim_buf_get_name(bufnr)
	local buftype = api.nvim_buf_get_option(bufnr, "buftype")

	-- Check if this is an unsaved Tear note
	if buftype == "acwrite" and current_file:match("%[Tear Note%]") then
		-- Allow setting name for unsaved notes
		if not new_name or new_name == "" then
			vim.ui.input({prompt = "Set name for note (without extension): "}, function(input)
				if input then
					api.nvim_buf_set_var(bufnr, "tear_unsaved_name", input)
					vim.notify("Name set to: " .. input .. M.config.notes.extension, vim.log.levels.INFO)
				end
			end)
			return
		end

		api.nvim_buf_set_var(bufnr, "tear_unsaved_name", new_name)
		vim.notify("Name set to: " .. new_name .. (new_name:match(vim.pesc(M.config.notes.extension) .. "$") and "" or M.config.notes.extension), vim.log.levels.INFO)
		return
	end

	-- Check if current file is in the notes directory
	if not current_file:match("^" .. vim.pesc(M.config.notes.path)) then
		vim.notify("Current file is not a tear note", vim.log.levels.WARN)
		return
	end

	if not new_name or new_name == "" then
		vim.ui.input({prompt = "New name (without extension): "}, function(input)
			if input then
				M.name(input)
			end
		end)
		return
	end

	-- Ensure the name has the correct extension
	if not new_name:match(vim.pesc(M.config.notes.extension) .. "$") then
		new_name = new_name .. M.config.notes.extension
	end

	local old_filename = fn.fnamemodify(current_file, ":t")
	local new_filepath = M.config.notes.path .. "/" .. new_name

	-- Check if target file already exists
	if fn.filereadable(new_filepath) == 1 then
		vim.notify("A file with that name already exists", vim.log.levels.ERROR)
		return
	end

	-- Rename the file
	local ok = os.rename(current_file, new_filepath)
	if not ok then
		vim.notify("Failed to rename file", vim.log.levels.ERROR)
		return
	end

	-- Update metadata cache
	if metadata_cache[old_filename] then
		metadata_cache[new_name] = metadata_cache[old_filename]
		metadata_cache[new_name].filepath = new_filepath
		metadata_cache[old_filename] = nil
		save_metadata()
	end

	-- Update the buffer
	api.nvim_buf_set_name(0, new_filepath)
	api.nvim_buf_set_option(0, "modified", false)

	vim.notify(string.format("Renamed: %s → %s", old_filename, new_name), vim.log.levels.INFO)
end

-- Reindex all notes (useful after manual changes)
function M.reindex()
	vim.notify("Reindexing notes...", vim.log.levels.INFO)
	metadata_cache = {}

	local notes_path = M.config.notes.path
	if fn.isdirectory(notes_path) == 0 then
		vim.notify("Notes directory does not exist", vim.log.levels.WARN)
		return
	end

	local files = vim.split(fn.glob(notes_path .. "/*" .. M.config.notes.extension), "\n")

	for _, filepath in ipairs(files) do
		if filepath ~= "" then
			local file = io.open(filepath, "r")
			if file then
				local content = file:read("*all")
				file:close()
				local lines = vim.split(content, "\n")
				update_metadata(filepath, lines)
			end
		end
	end

	save_metadata()
	vim.notify(string.format("Reindexed %d notes", vim.tbl_count(metadata_cache)), vim.log.levels.INFO)
end

-- Display hashtags from current buffer in the command line
function M.show_hashtags()
	local bufnr = api.nvim_get_current_buf()
	local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local tags = extract_hashtags(lines)

	if #tags > 0 then
		local tag_str = ""
		for _, tag in ipairs(tags) do
			tag_str = tag_str .. "#" .. tag .. " "
		end
		tag_str = tag_str:gsub("%s+$", "") -- Remove trailing space

		-- Get the foreground color of NonText (or LineNr)
		local hl = vim.api.nvim_get_hl_by_name("LineNr", true) -- true = get RGB
		-- hl.foreground is a number; convert to hex
		local fg_hex = string.format("#%06x", hl.foreground)

		-- Use echohl with a custom highlight
		vim.cmd(string.format("echohl NONE | echon ''")) -- reset
		vim.cmd(string.format("highlight MyTags guifg=%s", fg_hex))
		vim.cmd(string.format("echohl MyTags"))
		vim.cmd(string.format('echon "%s"', tag_str))
		vim.cmd("echohl NONE")
	end
end

-- Auto-display hashtags when cursor stops moving
function M.setup_auto_hashtag_display()
	local aug = api.nvim_create_augroup("TearHashtagDisplay", {clear = true})

	-- Update hashtags on cursor hold (after 'updatetime' ms of no cursor movement)
	api.nvim_create_autocmd({"CursorHold", "CursorHoldI"}, {
		group = aug,
		pattern = M.config.notes.path .. "/*" .. M.config.notes.extension,
		callback = function()
			M.show_hashtags()
		end,
	})

	-- Also update when entering a tear note buffer
	api.nvim_create_autocmd("BufEnter", {
		group = aug,
		pattern = M.config.notes.path .. "/*" .. M.config.notes.extension,
		callback = function()
			M.show_hashtags()
		end,
	})

	-- And when saving
	api.nvim_create_autocmd("BufWritePost", {
		group = aug,
		pattern = M.config.notes.path .. "/*" .. M.config.notes.extension,
		callback = function()
			M.show_hashtags()
		end,
	})
end

-- Setup function
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	M.config.notes.path = fn.expand(M.config.notes.path)

	ensure_directory(M.config.notes.path)
	metadata_cache = load_metadata()

	-- Create commands
	api.nvim_create_user_command("Tear", function() M.tear() end, {})
	api.nvim_create_user_command("TearRecent", function(opts)
		M.recent(tonumber(opts.args) or 10)
	end, {nargs = "?"})
	api.nvim_create_user_command("TearSearch", function(opts)
		M.search(opts.args)
	end, {nargs = "?"})
	api.nvim_create_user_command("TearVisualize", function() M.visualize() end, {})
	api.nvim_create_user_command("TearReindex", function() M.reindex() end, {})
	api.nvim_create_user_command("TearName", function(opts)
		M.name(opts.args)
	end, {nargs = "?"})

	-- Auto-update metadata when notes are saved
	local aug = api.nvim_create_augroup("TearAutoUpdate", {clear = true})
	api.nvim_create_autocmd("BufWritePost", {
		group = aug,
		pattern = M.config.notes.path .. "/*" .. M.config.notes.extension,
		callback = function(ev)
			-- Don't update if this is a new Tear note (handled by BufWriteCmd)
			local bufnr = ev.buf
			if api.nvim_buf_get_option(bufnr, "buftype") == "acwrite" then
				return
			end

			local filepath = ev.file
			local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
			update_metadata(filepath, lines)
		end,
	})

	if M.config.ui.enable_hashtag_display then
		M.setup_auto_hashtag_display()
	end
end

return M
