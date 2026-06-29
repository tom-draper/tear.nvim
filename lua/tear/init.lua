-- tear.nvim - Frictionless note-taking for Neovim

local M = {}
local api = vim.api
local fn = vim.fn

-- Default configuration
M.config = {
	notes = {
		path = vim.fn.expand("~/notes/tear"),
		extension = ".md",
		filename_strategy = "timestamp", -- "timestamp" or "content"
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

local function note_glob()
	return M.config.notes.path .. "/*" .. M.config.notes.extension
end

local function list_note_files()
	local files = vim.split(fn.glob(note_glob()), "\n", {trimempty = true})
	table.sort(files)
	return files
end

local function read_file_lines(filepath)
	local file = io.open(filepath, "r")
	if not file then
		return nil
	end

	local content = file:read("*all")
	file:close()
	return vim.split(content, "\n")
end

local function first_content_line(lines)
	for _, line in ipairs(lines) do
		local text = line:gsub("^#+%s*", ""):gsub("^%s*(.-)%s*$", "%1")
		if text ~= "" then
			return text
		end
	end

	return ""
end

local function make_excerpt(lines)
	local excerpt = first_content_line(lines)
	if #excerpt > 120 then
		excerpt = excerpt:sub(1, 117) .. "..."
	end

	return excerpt
end

local function has_extension(filename)
	return filename:match(vim.pesc(M.config.notes.extension) .. "$") ~= nil
end

local function ensure_extension(filename)
	if has_extension(filename) then
		return filename
	end

	return filename .. M.config.notes.extension
end

local function unique_filepath(filename)
	filename = ensure_extension(filename)

	local filepath = M.config.notes.path .. "/" .. filename
	local counter = 1

	while fn.filereadable(filepath) == 1 do
		local base = filename:match("(.+)%..+$") or filename
		local ext = filename:match("%.(.+)$") or ""
		if ext == "" then
			filepath = M.config.notes.path .. "/" .. base .. "-" .. counter
		else
			filepath = M.config.notes.path .. "/" .. base .. "-" .. counter .. "." .. ext
		end
		counter = counter + 1
	end

	return filepath
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

local function generate_filename(lines, custom_name)
	if custom_name and custom_name ~= "" then
		return ensure_extension(custom_name)
	end

	if M.config.notes.filename_strategy == "content" then
		return generate_filename_from_content(lines) .. M.config.notes.extension
	end

	return os.date(M.config.notes.datetime_format) .. M.config.notes.extension
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
local function update_metadata(filepath, lines, opts)
	opts = opts or {}
	local filename = fn.fnamemodify(filepath, ":t")
	local tags = extract_hashtags(lines)
	local keywords = extract_keywords(lines)
	local mtime = fn.getftime(filepath)

	metadata_cache[filename] = {
		created = metadata_cache[filename] and metadata_cache[filename].created or os.time(),
		modified = mtime > 0 and mtime or os.time(),
		tags = tags,
		keywords = keywords,
		excerpt = make_excerpt(lines),
		filepath = filepath,
	}

	if M.config.metadata.auto_persist and opts.persist ~= false then
		save_metadata()
	end
end

local function save_note(lines, custom_name)
	ensure_directory(M.config.notes.path)

	local filename = generate_filename(lines, custom_name)
	local filepath = unique_filepath(filename)
	local file = io.open(filepath, "w")

	if not file then
		vim.notify("Failed to save note", vim.log.levels.ERROR)
		return nil
	end

	file:write(table.concat(lines, "\n"))
	file:close()
	update_metadata(filepath, lines)

	return filepath
end

local function open_note(filepath)
	api.nvim_command("edit " .. fn.fnameescape(filepath))
end

local function note_display(note)
	local date = os.date("%Y-%m-%d %H:%M", note.modified or os.time())
	local tags = note.tags or {}
	local tags_str = #tags > 0 and " [#" .. table.concat(tags, " #") .. "]" or ""
	local excerpt = note.excerpt and note.excerpt ~= "" and (" - " .. note.excerpt) or ""

	return string.format("%s - %s%s%s", note.filename, date, tags_str, excerpt)
end

local function select_note(prompt, notes)
	if #notes == 0 then
		vim.notify("No notes found. Create one with :Tear", vim.log.levels.INFO)
		return
	end

	vim.ui.select(notes, {
		prompt = prompt,
		format_item = note_display,
	}, function(note)
		if note then
			open_note(note.filepath or (M.config.notes.path .. "/" .. note.filename))
		end
	end)
end

local function centered_float_config(line_count)
	local columns = math.max(1, vim.o.columns)
	local editor_lines = math.max(1, vim.o.lines - vim.o.cmdheight)
	local width = math.max(1, math.min(120, columns - 2, math.floor(columns * 0.9)))
	local height = math.max(1, math.min(line_count, editor_lines - 2))

	return {
		relative = "editor",
		width = width,
		height = height,
		col = math.max(0, math.floor((columns - width) / 2)),
		row = math.max(0, math.floor((editor_lines - height) / 2)),
		style = "minimal",
		border = "rounded",
		title = " Recent Notes ",
		title_pos = "center",
	}
end

local function truncate_display(text, width)
	if width <= 3 or fn.strdisplaywidth(text) <= width then
		return text
	end

	return fn.strcharpart(text, 0, width - 3) .. "..."
end

local function recent_note_picker(notes)
	if #notes == 0 then
		vim.notify("No notes found. Create one with :Tear", vim.log.levels.INFO)
		return
	end

	local function picker_lines(width)
		local lines = {}
		for i, note in ipairs(notes) do
			table.insert(lines, truncate_display(string.format("%d. %s", i, note_display(note)), width))
		end
		return lines
	end

	local config = centered_float_config(#notes)
	local lines = picker_lines(config.width)
	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	api.nvim_buf_set_option(buf, "modifiable", false)
	api.nvim_buf_set_option(buf, "filetype", "markdown")
	api.nvim_buf_set_option(buf, "bufhidden", "wipe")

	local win = api.nvim_open_win(buf, true, config)
	api.nvim_win_set_option(win, "wrap", false)
	api.nvim_win_set_option(win, "cursorline", true)

	local aug = api.nvim_create_augroup("TearRecentPicker_" .. buf, {clear = true})
	api.nvim_create_autocmd("VimResized", {
		group = aug,
		callback = function()
			if not api.nvim_win_is_valid(win) or not api.nvim_buf_is_valid(buf) then
				pcall(api.nvim_del_augroup_by_id, aug)
				return
			end

			local updated_config = centered_float_config(#notes)
			api.nvim_win_set_config(win, updated_config)
			api.nvim_buf_set_option(buf, "modifiable", true)
			api.nvim_buf_set_lines(buf, 0, -1, false, picker_lines(updated_config.width))
			api.nvim_buf_set_option(buf, "modifiable", false)
		end,
	})

	local function move(delta)
		local row = api.nvim_win_get_cursor(win)[1]
		row = math.max(1, math.min(#notes, row + delta))
		api.nvim_win_set_cursor(win, {row, 0})
	end

	local function open_selected()
		local row = api.nvim_win_get_cursor(win)[1]
		local note = notes[row]
		if note then
			pcall(api.nvim_del_augroup_by_id, aug)
			api.nvim_command("close")
			open_note(note.filepath or (M.config.notes.path .. "/" .. note.filename))
		end
	end

	local map_opts = {buffer = buf, nowait = true, silent = true}
	vim.keymap.set("n", "<CR>", open_selected, map_opts)
	vim.keymap.set("n", "q", function()
		pcall(api.nvim_del_augroup_by_id, aug)
		api.nvim_command("close")
	end, map_opts)
	vim.keymap.set("n", "<Esc>", function()
		pcall(api.nvim_del_augroup_by_id, aug)
		api.nvim_command("close")
	end, map_opts)
	vim.keymap.set("n", "j", function() move(1) end, map_opts)
	vim.keymap.set("n", "<Down>", function() move(1) end, map_opts)
	vim.keymap.set("n", "k", function() move(-1) end, map_opts)
	vim.keymap.set("n", "<Up>", function() move(-1) end, map_opts)
end

local function sorted_notes()
	local notes = {}
	for filename, meta in pairs(metadata_cache) do
		table.insert(notes, {
			filename = filename,
			modified = meta.modified,
			tags = meta.tags or {},
			keywords = meta.keywords or {},
			excerpt = meta.excerpt or "",
			filepath = meta.filepath or (M.config.notes.path .. "/" .. filename),
		})
	end

	table.sort(notes, function(a, b) return (a.modified or 0) > (b.modified or 0) end)
	return notes
end

local function metadata_is_stale()
	local files = list_note_files()
	if #files == 0 then
		return false
	end

	if vim.tbl_count(metadata_cache) == 0 then
		return true
	end

	local seen = {}
	for _, filepath in ipairs(files) do
		local filename = fn.fnamemodify(filepath, ":t")
		seen[filename] = true

		local meta = metadata_cache[filename]
		local mtime = fn.getftime(filepath)
		if not meta or not meta.excerpt or not meta.filepath or (mtime > 0 and meta.modified ~= mtime) then
			return true
		end
	end

	for filename, _ in pairs(metadata_cache) do
		if not seen[filename] then
			return true
		end
	end

	return false
end

local function reindex_notes(opts)
	opts = opts or {}
	if not opts.silent then
		vim.notify("Reindexing notes...", vim.log.levels.INFO)
	end

	metadata_cache = {}

	local notes_path = M.config.notes.path
	if fn.isdirectory(notes_path) == 0 then
		if not opts.silent then
			vim.notify("Notes directory does not exist", vim.log.levels.WARN)
		end
		return 0
	end

	for _, filepath in ipairs(list_note_files()) do
		local lines = read_file_lines(filepath)
		if lines then
			update_metadata(filepath, lines, {persist = false})
		end
	end

	save_metadata()

	local count = vim.tbl_count(metadata_cache)
	if not opts.silent then
		vim.notify(string.format("Reindexed %d notes", count), vim.log.levels.INFO)
	end

	return count
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

			-- First check if a custom name was set with :TearName
			local ok, custom_name = pcall(api.nvim_buf_get_var, bufnr, "tear_unsaved_name")
			local filepath = save_note(lines, ok and custom_name or nil)
			if not filepath then
				return
			end

			-- Clear the custom name variable since it's now saved
			if ok and custom_name then
				pcall(api.nvim_buf_del_var, bufnr, "tear_unsaved_name")
			end

			-- Update buffer to point to real file
			api.nvim_buf_set_option(bufnr, "buftype", "")
			api.nvim_buf_set_name(bufnr, filepath)
			api.nvim_buf_set_option(bufnr, "modified", false)

			-- Remove this BufWriteCmd handler so future ':w' writes go through
			-- Neovim's normal file-writing path instead of creating a new note.
			pcall(api.nvim_del_augroup_by_id, aug)

			vim.notify("Note saved: " .. fn.fnamemodify(filepath, ":t"), vim.log.levels.INFO)
		end,
	})

	vim.notify("New note", vim.log.levels.INFO)
end

-- Capture a single thought without leaving the current window
function M.quick(text)
	if text and text ~= "" then
		local filepath = save_note({text})
		if filepath then
			vim.notify("Note saved: " .. fn.fnamemodify(filepath, ":t"), vim.log.levels.INFO)
		end
		return
	end

	vim.ui.input({prompt = "Tear: "}, function(input)
		if not input or input == "" then
			return
		end

		local filepath = save_note({input})
		if filepath then
			vim.notify("Note saved: " .. fn.fnamemodify(filepath, ":t"), vim.log.levels.INFO)
		end
	end)
end

-- Show recent notes
function M.recent(count)
	count = count or 10

	local notes = {}
	for i, note in ipairs(sorted_notes()) do
		if i > count then
			break
		end
		table.insert(notes, note)
	end

	recent_note_picker(notes)
end

-- Search notes by tags or keywords
function M.search(query)
	if not query or query == "" then
		vim.ui.input({prompt = "Search (tag or keyword): "}, function(input)
			if input then
				vim.schedule(function()
					M.search(input)
				end)
			end
		end)
		return
	end

	local original_query = query
	query = query:lower()
	local tag_query = query:gsub("^#+", "")
	local results = {}

	for filename, meta in pairs(metadata_cache) do
		local score = 0

		-- Check tags
		for _, tag in ipairs(meta.tags or {}) do
			if tag:lower():find(tag_query, 1, true) then
				score = math.max(score, 100)
				break
			end
		end

		-- Check keywords
		if score == 0 then
			for _, keyword in ipairs(meta.keywords or {}) do
				if keyword:lower():find(query, 1, true) then
					score = math.max(score, 50)
					break
				end
			end
		end

		local excerpt = meta.excerpt or ""
		if score == 0 and excerpt:lower():find(query, 1, true) then
			score = math.max(score, 25)
		end

		if score == 0 then
			local filepath = meta.filepath or (M.config.notes.path .. "/" .. filename)
			local lines = read_file_lines(filepath)
			if lines then
				local content = table.concat(lines, "\n"):lower()
				if content:find(query, 1, true) then
					score = math.max(score, 10)
				end
			end
		end

		if score > 0 then
			table.insert(results, {
				filename = filename,
				tags = meta.tags or {},
				modified = meta.modified,
				excerpt = excerpt,
				filepath = meta.filepath or (M.config.notes.path .. "/" .. filename),
				score = score,
			})
		end
	end

	table.sort(results, function(a, b)
		if a.score == b.score then
			return (a.modified or 0) > (b.modified or 0)
		end

		return a.score > b.score
	end)

	if #results == 0 then
		vim.cmd("redraw")
		vim.notify(string.format("No notes found matching '%s'", original_query), vim.log.levels.INFO)
		return
	end

	select_note(string.format("Search notes: %s", original_query), results)
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

	local width = math.max(1, math.min(90, vim.o.columns - 4))
	local height = math.max(1, math.min(#lines + 2, vim.o.lines - 4))
	api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		row = math.max(0, math.floor((vim.o.lines - height) / 2)),
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
	reindex_notes()
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
		local ok, hl = pcall(vim.api.nvim_get_hl, 0, {name = "LineNr"})
		if not ok then
			ok, hl = pcall(vim.api.nvim_get_hl_by_name, "LineNr", true)
		end
		hl = ok and hl or {}
		local fg = hl.fg or hl.foreground or 0x808080
		local fg_hex = string.format("#%06x", fg)

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

	if M.config.notes.file_extension and not (opts and opts.notes and opts.notes.extension) then
		M.config.notes.extension = M.config.notes.file_extension
	end

	M.config.notes.path = fn.expand(M.config.notes.path)

	ensure_directory(M.config.notes.path)
	metadata_cache = load_metadata()
	if metadata_is_stale() then
		reindex_notes({silent = true})
	end

	-- Create commands
	api.nvim_create_user_command("Tear", function() M.tear() end, {})
	api.nvim_create_user_command("TearQuick", function(opts)
		M.quick(opts.args)
	end, {nargs = "*"})
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
