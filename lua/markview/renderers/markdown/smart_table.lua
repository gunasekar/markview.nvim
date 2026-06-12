--[[
Smart table rendering for `markview.nvim`(`markdown.tables.smart_wrap`).

Kept out of `renderers/markdown.lua` so the core renderer's footprint is a
single hook. Public API,

  * `M.render(buffer, item, config, ns)` — redraw the whole fitted table as
    virtual lines over the hidden(`conceal_lines`) source rows. Returns
    `false`(without rendering) when the table should be handled by the legacy
    path instead: always on Neovim < 0.11, and under `'nowrap'` whenever the
    table already fits the window(the in-buffer rendering is preferable —
    real text, visible cursor).

The pure column-fit & word-wrap maths(`fit_columns`, `word_wrap`) are defined
below and exposed on `M` so they can be unit-tested in isolation.

Because the layout is sized to the window, the first `M.render` call also
registers a `WinResized`/`VimResized` autocmd that re-renders the affected
buffers — without it a layout change(sidebar, split, terminal resize) would
leave tables at the stale width. Buffers that never render a smart table never
get this autocmd.
]]
local M = {};

local utils = require("markview.utils");
local spec = require("markview.spec");

---|fS "feat: Re-render on window resize"

---@diagnostic disable-next-line: undefined-field
local resize_timer = vim.uv.new_timer();

---@param args vim.api.keyset.create_autocmd.callback_args
local function on_resized (args)
	local state = require("markview.state");

	if not state.enabled() then
		return;
	end

	--- `smart_wrap` may have been turned off after this autocmd was
	--- registered; without it nothing is sized to the window.
	if spec.get({ "markdown", "tables", "smart_wrap" }, { fallback = false, ignore_enable = true }) ~= true then
		return;
	end

	--- `WinResized` reports the affected windows; `VimResized` does not, but
	--- it resizes the whole layout, so every window is affected.
	---
	--- NOTE: `vim.v.event` is only valid *inside* the autocmd, so the buffer
	--- list must be resolved before deferring.
	---@type integer[]
	local wins = (args.event == "WinResized" and vim.v.event and vim.v.event.windows)
		or vim.api.nvim_tabpage_list_wins(0);

	local bufs, seen = {}, {};

	for _, win in ipairs(wins) do
		if vim.api.nvim_win_is_valid(win) then
			local buf = vim.api.nvim_win_get_buf(win);

			if not seen[buf] and state.buf_attached(buf) and buf ~= state.get_splitview_source() then
				local buf_state = state.get_buffer_state(buf, false);

				if buf_state and buf_state.enable then
					seen[buf] = true;
					bufs[#bufs + 1] = buf;
				end
			end
		end
	end

	if #bufs == 0 then
		return;
	end

	local delay = spec.get({ "preview", "debounce" }, { fallback = 25, ignore_enable = true });

	resize_timer:stop();
	resize_timer:start(delay, 0, vim.schedule_wrap(function ()
		local actions = require("markview.actions");

		if not actions.in_preview_mode() then
			return;
		end

		for _, buf in ipairs(bufs) do
			if vim.api.nvim_buf_is_valid(buf) then
				actions.render(buf);
			end
		end
	end));
end

local resize_group;

--- Registers the resize autocmd(once).
local function register_resize ()
	if resize_group then
		return;
	end

	resize_group = vim.api.nvim_create_augroup("markview.smart_table.resize", { clear = true });

	vim.api.nvim_create_autocmd({
		"WinResized", "VimResized"
	}, {
		group = resize_group,
		callback = on_resized
	});
end

---|fE

--- Takes the longest prefix of {str} whose display width is `≤ {width}`.
---
--- Unicode-aware(splits on character boundaries, accounts for wide glyphs).
--- Always consumes at least one character to avoid infinite loops.
---@param str string
---@param width integer
---@return string prefix
---@return string rest
local function take_prefix (str, width)
	---|fS

	local chars = vim.fn.split(str, "\\zs");
	local out, w, idx = "", 0, 0;

	for i, ch in ipairs(chars) do
		local cw = vim.fn.strdisplaywidth(ch);

		if w + cw > width then
			break;
		end

		out = out .. ch;
		w = w + cw;
		idx = i;
	end

	if idx == 0 then
		--- A single character wider than {width}; take it anyway so we make
		--- progress.
		out = chars[1] or "";
		idx = 1;
	end

	local rest = table.concat(vim.list_slice(chars, idx + 1), "");
	return out, rest;

	---|fE
end

--- Word-wraps {text} into lines of display width `≤ {width}`.
---
--- Breaks on whitespace where possible and hard-breaks a single word that is
--- wider than {width}. Collapses runs of inter-word whitespace into a single
--- space(matching how the wrapped text is re-drawn).
---@param text string
---@param width integer
---@return string[]
M.word_wrap = function (text, width)
	---|fS

	width = math.max(1, width);

	local lines = {};
	local cur, cur_w = "", 0;

	for word in string.gmatch(text, "%S+") do
		local ww = vim.fn.strdisplaywidth(word);

		if ww > width then
			--- Word is too long, flush the current line then hard-break the
			--- word across as many lines as needed.
			if cur ~= "" then
				table.insert(lines, cur);
				cur, cur_w = "", 0;
			end

			local rest = word;

			while vim.fn.strdisplaywidth(rest) > width do
				local pre, r = take_prefix(rest, width);
				table.insert(lines, pre);
				rest = r;
			end

			cur, cur_w = rest, vim.fn.strdisplaywidth(rest);
		elseif cur_w == 0 then
			cur, cur_w = word, ww;
		elseif cur_w + 1 + ww <= width then
			cur = cur .. " " .. word;
			cur_w = cur_w + 1 + ww;
		else
			table.insert(lines, cur);
			cur, cur_w = word, ww;
		end
	end

	if cur ~= "" or #lines == 0 then
		table.insert(lines, cur);
	end

	return lines;

	---|fE
end

--- Shrinks {natural} column widths so that the rendered table fits inside
--- {budget} display columns.
---
--- Columns wider than the rest are shrunk first(so narrow columns keep their
--- content) but never below {min_col}. If everything already fits, the natural
--- widths are returned unchanged.
---@param natural integer[]
---@param budget integer Display columns available for cell content(borders excluded).
---@param min_col integer Smallest width a column may shrink to.
---@return integer[] fitted
---@return boolean shrunk Whether any column was actually narrowed.
M.fit_columns = function (natural, budget, min_col)
	---|fS

	local fitted = {};
	local total = 0;

	for i, w in ipairs(natural) do
		fitted[i] = w;
		total = total + w;
	end

	if #fitted == 0 or total <= budget then
		return fitted, false;
	end

	local shrunk = false;
	local guard = 0;

	--- Shave one cell off the widest column wider than {floor}, repeatedly,
	--- until the table fits the budget or no column can shrink further. Tables
	--- are small, so this stays cheap; the guard is only a runaway safety net.
	local function shrink_to (floor)
		while total > budget and guard < 200000 do
			guard = guard + 1;

			local widest, wi = -1, nil;

			for i, w in ipairs(fitted) do
				if w > floor and w > widest then
					widest = w;
					wi = i;
				end
			end

			if not wi then
				break;
			end

			fitted[wi] = fitted[wi] - 1;
			total = total - 1;
			shrunk = true;
		end
	end

	--- First honour `min_col`. If the budget is so tight that even every column
	--- at `min_col` still overflows(very narrow window + many columns), force
	--- columns below it down to 1 so the table never exceeds the budget —
	--- readability yields to fitting at extreme widths.
	shrink_to(min_col);

	if total > budget then
		shrink_to(1);
	end

	return fitted, shrunk;

	---|fE
end


--- Target width(in cells) the rendered table must fit in, from `wrap_width`:
---   * a fraction in `(0, 1]` — that share of the window width(`0.9` ⇒ 90%).
---   * an integer `> 1`       — an absolute column count(clamped to the window).
---   * anything else          — defaults to 90% of the window.
---@param win integer
---@param config markview.config.markdown.tables
---@return integer
local function fit_target (win, config)
	local info = vim.fn.getwininfo(win)[1];
	local textoff = info and info.textoff or 0;
	local win_width = vim.api.nvim_win_get_width(win) - textoff;

	local ww = config.wrap_width;

	if type(ww) == "number" and ww > 0 and ww <= 1 then
		return math.floor(win_width * ww);
	elseif type(ww) == "number" and ww > 1 then
		return math.min(win_width, math.floor(ww));
	else
		return math.floor(win_width * 0.9);
	end
end

--- Fully-virtual table renderer.
---
--- Hides every real table line with `conceal_lines`(0 screen height) and
--- redraws the whole table as `virt_lines`, fitted to `wrap_width` with each
--- cell word-wrapped — exactly how a CLI renderer emits output.
---
--- With `'wrap'` on this handles every table: soft-wrap computes break points
--- from raw buffer columns, which is fatal to the normal(inline `virt_text` +
--- `conceal`) rendering. With `'wrap'` off it only handles tables that
--- overflow the fit target(fitting tables return `false` -> legacy path).
---
--- Editing is handled by markview's existing hybrid mode: when the cursor is on
--- the table the node is filtered out before rendering, so these decorations
--- are not drawn and the raw markdown shows through.
---@param buffer integer
---@param item markview.parsed.markdown.tables
---@param config markview.config.markdown.tables
---@param ns integer Markdown renderer namespace.
---@return boolean rendered Whether the virtual table was drawn(false -> caller should fall back).
M.render = function (buffer, item, config, ns)
	---|fS

	--- Smart tables are sized to the window, so resizes must re-render(see
	--- the module header). Registered here — not at module load — so the
	--- autocmd only ever exists once a smart table is actually rendered.
	register_resize();

	--- `conceal_lines`(used to hide the real rows) needs Neovim 0.11+. On older
	--- versions the extmark would error, so bail and let the caller fall back to
	--- the legacy rendering path.
	if vim.fn.has("nvim-0.11") == 0 then
		return false;
	end

	--- `linewise` hybrid mode clears decorations line-by-line around the
	--- cursor. That would strip some of this table's `conceal_lines` while the
	--- full virtual copy stays drawn — duplicating rows on screen. An
	--- all-or-nothing virtual table cannot honour per-line reveals, so fall
	--- back to the legacy rendering instead.
	if
		spec.get({ "preview", "linewise_hybrid_mode" }, { fallback = false, ignore_enable = true }) == true and
		#spec.get({ "preview", "hybrid_modes" }, { fallback = {}, ignore_enable = true }) > 0
	then
		return false;
	end

	local range = item.range;
	local win = utils.buf_getwin(buffer);

	if type(win) ~= "number" then
		return false;
	end

	local md_tostring = require("markview.renderers.markdown.tostring");

	--- Rendered(markup-concealed) text of each `column` cell in {cells}.
	local function cell_texts (cells)
		local out = {};

		for _, col in ipairs(cells) do
			if col.class == "column" then
				out[#out + 1] = vim.trim(md_tostring.tostring(buffer, col.text or ""));
			end
		end

		return out;
	end

	local header = cell_texts(item.header);
	local rows = {};

	for _, r in ipairs(item.rows) do
		rows[#rows + 1] = cell_texts(r);
	end

	--- A line the row-parser could not split into columns(e.g. mid-edit, text
	--- typed before the leading `|`) would be drawn as an *empty* row here —
	--- hiding real text, as every source line is concealed below. The legacy
	--- path keeps such lines visible, so let it handle the table instead.
	if #header == 0 then
		return false;
	end

	for _, r in ipairs(rows) do
		if #r == 0 then
			return false;
		end
	end

	local ncols = #header;
	for _, r in ipairs(rows) do
		ncols = math.max(ncols, #r);
	end

	if ncols == 0 then
		return false;
	end

	--- Natural column widths(ignoring the separator row).
	local natural = {};
	for c = 1, ncols do natural[c] = 1; end

	local function accumulate (texts)
		for c = 1, ncols do
			natural[c] = math.max(natural[c], vim.fn.strdisplaywidth(texts[c] or ""));
		end
	end

	accumulate(header);
	for _, r in ipairs(rows) do accumulate(r); end

	--- Fit to `wrap_width`. Each column is drawn as `" " .. cell .. " "`(width +
	--- 2) with `ncols + 1` vertical borders.
	local min_col = type(config.wrap_minwidth) == "number" and config.wrap_minwidth or 5;
	local budget = fit_target(win, config) - range.col_start - ((ncols + 1) + (2 * ncols));
	local widths, shrunk = M.fit_columns(natural, budget, min_col);

	--- With `'wrap'` off the legacy in-buffer rendering works fine(real text,
	--- visible cursor) — only take over tables that actually overflow the fit
	--- target. With `'wrap'` on every table is virtualised, as soft-wrap breaks
	--- the in-buffer rendering.
	if vim.wo[win].wrap ~= true and shrunk ~= true then
		return false;
	end

	local aligns = item.alignments or {};
	local parts = config.parts or {};
	local hls = config.hl or {};

	local function H (group)
		return utils.set_hl(group);
	end

	--- Top/bottom border: corner, fill, junction, corner.
	local function junction_line (p, h)
		p = p or {}; h = h or {};
		local line = { { string.rep(" ", range.col_start) }, { p[1] or "", H(h[1]) } };

		for i = 1, ncols do
			line[#line + 1] = { string.rep(p[2] or "─", widths[i] + 2), H(h[2]) };
			line[#line + 1] = { (i == ncols and p[3] or p[4]) or "", H(i == ncols and h[3] or h[4]) };
		end

		return line;
	end

	--- Separator row, with alignment markers.
	local function separator_line ()
		local p = parts.separator or {};
		local h = hls.separator or {};
		local line = { { string.rep(" ", range.col_start) }, { p[1] or "", H(h[1]) } };
		local fill = p[2] or "─";

		for i = 1, ncols do
			local w = widths[i] + 2;
			local mid;

			if aligns[i] == "left" then
				mid = (parts.align_left or "") .. string.rep(fill, math.max(0, w - 1));
			elseif aligns[i] == "right" then
				mid = string.rep(fill, math.max(0, w - 1)) .. (parts.align_right or "");
			elseif aligns[i] == "center" then
				local ac = parts.align_center or { "", "" };
				mid = (ac[1] or "") .. string.rep(fill, math.max(0, w - 2)) .. (ac[2] or "");
			else
				mid = string.rep(fill, w);
			end

			line[#line + 1] = { mid, H(h[2]) };
			line[#line + 1] = { (i == ncols and p[3] or p[4]) or "", H(i == ncols and h[3] or h[4]) };
		end

		return line;
	end

	--- A content row: `bars` = `parts.header`/`parts.row`, `segs` = the k-th
	--- wrapped line of each column.
	local function content_line (segs, bars, bhl, center)
		bars = bars or {}; bhl = bhl or {};
		local line = { { string.rep(" ", range.col_start) }, { bars[1] or "│", H(bhl[1]) } };

		for i = 1, ncols do
			local seg = segs[i] or "";
			local pad = math.max(0, widths[i] - vim.fn.strdisplaywidth(seg));
			local lp, rp;

			--- The header row is always centred; data rows follow the column's
			--- own alignment.
			local align = center and "center" or aligns[i];

			if align == "right" then
				lp, rp = pad, 0;
			elseif align == "center" then
				lp = math.floor(pad / 2); rp = pad - lp;
			else
				lp, rp = 0, pad;
			end

			line[#line + 1] = { " " .. string.rep(" ", lp) .. seg .. string.rep(" ", rp) .. " " };
			line[#line + 1] = { (i == ncols and bars[3] or bars[2]) or "│", H(i == ncols and bhl[3] or bhl[2]) };
		end

		return line;
	end

	--- Emits the wrapped content rows for one logical row of cell texts.
	local function emit_rows (vlines, texts, bars, bhl, center)
		local wrapped, n = {}, 1;

		for c = 1, ncols do
			wrapped[c] = M.word_wrap(texts[c] or "", widths[c]);
			n = math.max(n, #wrapped[c]);
		end

		for k = 1, n do
			local segs = {};
			for c = 1, ncols do segs[c] = wrapped[c][k] or ""; end
			vlines[#vlines + 1] = content_line(segs, bars, bhl, center);
		end
	end

	local vlines = {};
	vlines[#vlines + 1] = junction_line(parts.top, hls.top);
	emit_rows(vlines, header, parts.header, hls.header, true);
	vlines[#vlines + 1] = separator_line();
	for ri, r in ipairs(rows) do
		--- Thin rule between data rows so wrapped(multi-line) rows stay
		--- readable. Reuses the separator glyphs in the table border
		--- colour(`hls.bottom`).
		if ri > 1 then
			vlines[#vlines + 1] = junction_line(parts.separator, hls.bottom);
		end
		emit_rows(vlines, r, parts.row, hls.row);
	end
	vlines[#vlines + 1] = junction_line(parts.bottom, hls.bottom);

	--- Hide every real table line(0 screen height -> immune to soft-wrap).
	local nlines = #(item.text or {});
	if nlines == 0 then
		return false;
	end

	for r = range.row_start, range.row_start + nlines - 1 do
		vim.api.nvim_buf_set_extmark(buffer, ns, r, 0, {
			undo_restore = false, invalidate = true,
			conceal_lines = ""
		});
	end

	--- Attach the virtual table to a *visible* line(virt_lines on a concealed
	--- line are not drawn): prefer the line above the table, else the line after
	--- it.
	if range.row_start > 0 then
		vim.api.nvim_buf_set_extmark(buffer, ns, range.row_start - 1, 0, {
			undo_restore = false, invalidate = true,
			virt_lines = vlines
		});
	else
		local after = range.row_start + nlines;
		if after <= vim.api.nvim_buf_line_count(buffer) - 1 then
			vim.api.nvim_buf_set_extmark(buffer, ns, after, 0, {
				undo_restore = false, invalidate = true,
				virt_lines = vlines,
				virt_lines_above = true
			});
		else
			--- Table spans the whole buffer with no neighbour to anchor to.
			return false;
		end
	end

	return true;

	---|fE
end

return M;
