local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local ConfirmBox = require("ui/widget/confirmbox")
local FrameContainer = require("ui/widget/container/framecontainer")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ProgressWidget = require("ui/widget/progresswidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Blitbuffer = require("ffi/blitbuffer")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Size = require("ui/size")
local time = require("ui/time")
local _ = require("gettext")

local CACHE_DIR = DataStorage:getDataDir() .. "/textreflow"
local FORCE_OCR_SETTING = "textreflow_force_ocr_v1"
local OCR_LANGUAGE_SETTING = "textreflow_ocr_language_v1"
local OCR_RANGE_START_SETTING = "textreflow_ocr_range_start_v1"
local OCR_RANGE_END_SETTING = "textreflow_ocr_range_end_v1"
local FAILED_PAGES_SETTING = "textreflow_failed_pages_v1"
local SOURCE_PDF_SETTING = "textreflow_source_pdf_v1"
local SOURCE_FORCE_OCR_SETTING = "textreflow_source_force_ocr_v1"
local SOURCE_OCR_LANGUAGE_SETTING = "textreflow_source_ocr_language_v1"
local PENDING_ANNOTATIONS_SETTING = "textreflow_pending_annotations_v1"
local MAPPED_ANNOTATIONS_SETTING = "textreflow_mapped_annotations_v1"
local PENDING_PDF_ANNOTATIONS_SETTING = "textreflow_pending_pdf_annotations_v1"
local Screen = Device.screen

local TextReflow = WidgetContainer:extend{
    name = "textreflow",
    is_doc_only = true,
}

local ProgressDialog = InputContainer:extend{
    redraw_interval = 1.5,
}

function ProgressDialog:init()
    self.dimen = Screen:getSize()
    self._last_redraw = time.now()
    local width = math.floor(Screen:getWidth() * 0.8)
    self.title_bar = TitleBar:new{
        width = width,
        align = "left",
        title = _("Preparing text companion"),
        with_bottom_line = true,
    }
    self.progress_bar = ProgressWidget:new{
        width = width - 2 * Size.padding.large,
        height = Screen:scaleBySize(18),
        percentage = 0,
        fillcolor = Blitbuffer.COLOR_BLACK,
    }
    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = Size.padding.large,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            self.title_bar,
            VerticalSpan:new{ width = Size.padding.large },
            self.progress_bar,
        },
    }
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.frame,
    }
end

function ProgressDialog:show()
    UIManager:show(self, "ui")
    UIManager:forceRePaint()
end

function ProgressDialog:update(done, total, page)
    self.progress_bar:setPercentage(done / math.max(1, total))
    local now = time.now()
    if time.to_s(now - self._last_redraw) < self.redraw_interval then
        return
    end
    self._last_redraw = now
    self.title_bar:setTitle(string.format(_("Preparing page %d of %d"), page, total))
    UIManager:setDirty(self, "ui")
    UIManager:forceRePaint()
end

local function showMessage(text)
    UIManager:show(InfoMessage:new{
        text = text,
        width_factor = 0.9,
        height = math.max(1, math.min(
            math.floor(Screen:getHeight() * 0.6),
            Screen:getHeight() - 2 * Size.padding.large)),
        show_icon = false,
    })
end

local function flushSettings(settings)
    if not settings or type(settings.flush) ~= "function" then
        return true
    end
    local ok, result = pcall(settings.flush, settings)
    if not ok then
        return nil, tostring(result)
    end
    if result == false then
        return nil, _("Could not save document settings.")
    end
    return true
end

local function ensureCacheDirectory()
    local data_dir = DataStorage:getDataDir()
    if lfs.attributes(data_dir, "mode") ~= "directory" then
        return nil, _("KOReader's data directory is unavailable.")
    end
    if lfs.attributes(CACHE_DIR, "mode") ~= "directory" then
        local ok, err = lfs.mkdir(CACHE_DIR)
        if not ok and lfs.attributes(CACHE_DIR, "mode") ~= "directory" then
            return nil, err
        end
    end
    return true
end

local function ensureDirectory(path)
    if lfs.attributes(path, "mode") == "directory" then
        return true
    end
    local parent = path:match("^(.*)/[^/]+$")
    if not parent or parent == path then
        return nil, _("The TextReflow sidecar directory is unavailable.")
    end
    local parent_ok, parent_error = ensureDirectory(parent)
    if not parent_ok then
        return nil, parent_error
    end
    local ok, err = lfs.mkdir(path)
    if not ok and lfs.attributes(path, "mode") ~= "directory" then
        return nil, err or _("Could not create the TextReflow sidecar directory.")
    end
    return true
end

local function pathHash(path)
    local first, second = 5381, 2166136261
    for index = 1, #path do
        local byte = path:byte(index)
        first = (first * 33 + byte) % 4294967296
        second = (second * 65599 + byte) % 4294967296
    end
    return tostring(math.floor(first)) .. "-" .. tostring(math.floor(second))
end

local function pathsForPdf(pdf_path)
    local ok, err = ensureCacheDirectory()
    if not ok then
        return nil, err
    end
    local sidecar_ok, sidecar_dir = pcall(
        DocSettings.getSidecarDir, DocSettings, pdf_path)
    if not sidecar_ok or type(sidecar_dir) ~= "string" or sidecar_dir == "" then
        return nil, _("Could not locate the PDF's KOReader sidecar directory.")
    end
    local sidecar_textreflow = sidecar_dir .. "/textreflow"
    local sidecar_created, sidecar_error = ensureDirectory(sidecar_textreflow)
    if not sidecar_created then
        return nil, sidecar_error
    end
    local attributes = lfs.attributes(pdf_path) or {}
    local identity = table.concat({
        pdf_path,
        tostring(attributes.size or ""),
        tostring(attributes.modification or ""),
    }, "\n")
    local document_id = pathHash(pdf_path)
    local revision_id = pathHash(identity)
    local stem = sidecar_textreflow .. "/" .. document_id .. "-" .. revision_id
    local legacy_stem = CACHE_DIR .. "/" .. pathHash(identity)
    return {
        text = legacy_stem .. ".txt",
        cache = stem .. ".jsonl",
        legacy_cache = legacy_stem .. ".jsonl",
        textreflow_dir = sidecar_textreflow,
        document_id = document_id,
    }
end

local writeTextFile

local function readPageCache(path)
    local pages = {}
    local file, err = io.open(path, "rb")
    if not file then
        if lfs.attributes(path, "mode") then
            return nil, err or _("Could not read the OCR cache.")
        end
        return pages
    end

    local contents, read_error = file:read("*a")
    file:close()
    if type(contents) ~= "string" then
        return nil, read_error or _("Could not read the OCR cache.")
    end
    local lines = {}
    for line in (contents .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then
            lines[#lines + 1] = line
        end
    end
    local valid_lines = {}
    for line_number, line in ipairs(lines) do
        local ok, record = pcall(json.decode, line)
        if not ok or type(record) ~= "table"
            or type(record.page) ~= "number"
            or type(record.text) ~= "string"
            or type(record.force_ocr) ~= "boolean" then
            if line_number ~= #lines then
                return nil, string.format(_("The OCR cache is invalid at line %d."), line_number)
            end
            local recovered = #valid_lines > 0
                and table.concat(valid_lines, "\n") .. "\n" or ""
            local repaired, repair_error = writeTextFile(path, recovered)
            if not repaired then
                return nil, _("The final OCR cache record is incomplete and could not be repaired: ")
                    .. tostring(repair_error)
            end
            return pages, _("Recovered an incomplete OCR cache record; its page will be recognized again.")
        end
        pages[record.page] = record
        valid_lines[#valid_lines + 1] = line
    end
    return pages
end

local function readPdfPageCache(paths)
    if lfs.attributes(paths.cache, "mode") then
        return readPageCache(paths.cache)
    end
    if paths.legacy_cache and lfs.attributes(paths.legacy_cache, "mode") then
        return readPageCache(paths.legacy_cache)
    end
    return readPageCache(paths.cache)
end

local function getInstalledOcrLanguages()
    local ok, languages = pcall(function()
        return require("ui/data/ocr").getOCRLangs()
    end)
    if not ok then
        logger.warn("TextReflow could not list installed OCR languages:", languages)
        return nil
    end
    if type(languages) ~= "table" then
        return nil
    end
    return languages
end

local function appendPageCache(path, page, text, force_ocr, language)
    local encoded_ok, encoded = pcall(json.encode, {
        page = page,
        text = text,
        force_ocr = force_ocr,
        language = language,
    })
    if not encoded_ok or type(encoded) ~= "string" then
        return nil, _("Could not encode OCR text for the cache.")
    end
    local file, err = io.open(path, "ab")
    if not file then
        return nil, err
    end
    local wrote, write_error = file:write(encoded, "\n")
    local flushed, flush_error
    if wrote then
        flushed, flush_error = file:flush()
    end
    local closed, close_error = file:close()
    if not wrote or not flushed or not closed then
        return nil, write_error or flush_error or close_error or _("Could not save the OCR cache.")
    end
    return true
end

writeTextFile = function(path, contents)
    local existing = io.open(path, "rb")
    if existing then
        local current = existing:read("*a")
        existing:close()
        if current == contents then
            return true
        end
    end
    local temporary = path .. ".tmp"
    local file, err = io.open(temporary, "wb")
    if not file then
        return nil, err
    end
    local wrote, write_error = file:write(contents)
    local flushed, flush_error
    if wrote then
        flushed, flush_error = file:flush()
    end
    local closed, close_error = file:close()
    if not wrote or not flushed or not closed then
        os.remove(temporary)
        return nil, write_error or flush_error or close_error or _("Could not write the text companion.")
    end
    local renamed, rename_error = os.rename(temporary, path)
    if not renamed then
        os.remove(temporary)
        return nil, rename_error or _("Could not finish writing the text companion.")
    end
    return true
end

local function writeTextChunks(path, next_chunk)
    local existing = io.open(path, "rb")
    local identical = existing ~= nil
    local temporary = path .. ".tmp"
    local output, open_error = io.open(temporary, "wb")
    if not output then
        if existing then existing:close() end
        return nil, open_error
    end
    while true do
        local chunk, chunk_error = next_chunk()
        if chunk_error then
            output:close()
            if existing then existing:close() end
            os.remove(temporary)
            return nil, chunk_error
        end
        if not chunk then
            break
        end
        local wrote, write_error = output:write(chunk)
        if not wrote then
            output:close()
            if existing then existing:close() end
            os.remove(temporary)
            return nil, write_error or _("Could not write generated text.")
        end
        if identical and existing:read(#chunk) ~= chunk then
            identical = false
        end
    end
    if identical and existing:read(1) ~= nil then
        identical = false
    end
    if existing then existing:close() end
    local flushed, flush_error = output:flush()
    local closed, close_error = output:close()
    if not flushed or not closed then
        os.remove(temporary)
        return nil, flush_error or close_error or _("Could not finish writing generated text.")
    end
    if identical then
        local removed, remove_error = os.remove(temporary)
        if not removed then
            return nil, remove_error or _("Could not remove a temporary text file.")
        end
        return true
    end
    local renamed, rename_error = os.rename(temporary, path)
    if not renamed then
        os.remove(temporary)
        return nil, rename_error or _("Could not finish writing generated text.")
    end
    return true
end

local function writePageCache(path, pages, page_count)
    local page = 0
    local wrote_record = false
    local wrote_empty_cache = false
    return writeTextChunks(path, function()
        while page < page_count do
            page = page + 1
            local cached = pages[page]
            if cached then
                local ok, encoded = pcall(json.encode, {
                    page = page,
                    text = cached.text,
                    force_ocr = cached.force_ocr,
                    language = cached.language,
                })
                if not ok or type(encoded) ~= "string" then
                    return nil, _("Could not encode the completed OCR cache.")
                end
                wrote_record = true
                return encoded .. "\n"
            end
        end
        if not wrote_record and not wrote_empty_cache then
            wrote_empty_cache = true
            return "\n"
        end
        return nil
    end)
end

local function normalizeWord(word)
    return tostring(word or ""):lower():gsub("[%p%c%s]+", "")
end

local function tokensFromText(text)
    local tokens = {}
    for word in tostring(text or ""):gmatch("%S+") do
        local normalized = normalizeWord(word)
        if normalized ~= "" then
            tokens[#tokens + 1] = normalized
        end
    end
    return tokens
end

local function collectWordBoxes(text_boxes)
    local words = {}
    local lines = {}
    for _, line in ipairs(text_boxes or {}) do
        local line_words = {}
        if type(line) == "table" then
            for _, box in ipairs(line) do
                if type(box) == "table" and type(box.word) == "string" and box.word ~= "" then
                    line_words[#line_words + 1] = box.word
                    words[#words + 1] = {
                        word = box.word,
                        x0 = tonumber(box.x0),
                        y0 = tonumber(box.y0),
                        x1 = tonumber(box.x1),
                        y1 = tonumber(box.y1),
                    }
                end
            end
        end
        if #line_words > 0 then
            lines[#lines + 1] = table.concat(line_words, " ")
        end
    end
    return table.concat(lines, "\n"), words
end

local function extractPage(doc, page_number, force_ocr, language)
    local configurable = doc.configurable
    if type(configurable) ~= "table" then
        return nil, nil, _("The PDF does not expose configurable OCR settings.")
    end
    local old_wrap = configurable.text_wrap
    local old_forced_ocr = configurable.forced_ocr
    local old_language = configurable.doc_language
    local ok, text_boxes = pcall(function()
        configurable.text_wrap = 0
        configurable.doc_language = language or old_language
        configurable.forced_ocr = force_ocr and 1 or old_forced_ocr
        return doc:getTextBoxes(page_number)
    end)
    local restored, restore_error = pcall(function()
        configurable.text_wrap = old_wrap
        configurable.forced_ocr = old_forced_ocr
        configurable.doc_language = old_language
    end)
    if not restored then
        return nil, nil, _("Could not restore the PDF's OCR settings: ") .. tostring(restore_error)
    end
    if not ok then
        return nil, nil, tostring(text_boxes)
    end
    if type(text_boxes) ~= "table" then
        return nil, nil, _("KOReader returned no text boxes for this page.")
    end
    local text, words = collectWordBoxes(text_boxes)
    return text, words
end

local function findUniqueSequence(haystack, needle)
    if #needle == 0 or #needle > #haystack then
        return nil, 0
    end
    local found, count
    count = 0
    for start = 1, #haystack - #needle + 1 do
        local matches = true
        for offset = 1, #needle do
            if haystack[start + offset - 1] ~= needle[offset] then
                matches = false
                break
            end
        end
        if matches then
            found = start
            count = count + 1
            if count > 1 then
                return nil, count
            end
        end
    end
    return found, count
end

local function findVisibleSourcePage(ui, pages)
    local screen = Device.screen
    local ok, selection = pcall(
        ui.document.getTextFromPositions,
        ui.document,
        { x = 0, y = 0 },
        { x = screen:getWidth(), y = screen:getHeight() },
        true
    )
    if not ok or type(selection) ~= "table" or type(selection.text) ~= "string" then
        return nil
    end
    local visible_tokens = tokensFromText(selection.text)
    local page_texts = {}
    for page, record in pairs(pages) do
        page_texts[page] = " " .. table.concat(tokensFromText(record.text), " ") .. " "
    end

    for length = math.min(10, #visible_tokens), 4, -1 do
        local last_start = math.min(#visible_tokens - length + 1, 25)
        for start = 1, last_start do
            local phrase_tokens = {}
            for offset = 1, length do
                phrase_tokens[offset] = visible_tokens[start + offset - 1]
            end
            local phrase = " " .. table.concat(phrase_tokens, " ") .. " "
            local match_page, total_matches
            total_matches = 0
            for page, text in pairs(page_texts) do
                local position = 1
                while total_matches <= 1 do
                    local found = text:find(phrase, position, true)
                    if not found then
                        break
                    end
                    match_page = page
                    total_matches = total_matches + 1
                    position = found + 1
                end
                if total_matches > 1 then break end
            end
            if total_matches == 1 then
                return match_page
            end
        end
    end
    return nil
end

local function annotationCopy(annotation)
    if type(annotation) ~= "table"
        or (type(annotation.text) ~= "string" or annotation.text == "")
            and (type(annotation.note) ~= "string" or annotation.note == "") then
        return nil
    end
    return {
        text = type(annotation.text) == "string" and annotation.text or "",
        note = annotation.note,
        color = annotation.color,
        drawer = annotation.drawer,
        datetime = annotation.datetime,
        chapter = annotation.chapter,
        page = annotation.page
            or (type(annotation.pos0) == "table" and annotation.pos0.page),
        textreflow_id = annotation.textreflow_id,
        textreflow_source_page = annotation.textreflow_source_page,
        textreflow_source_pdf = annotation.textreflow_source_pdf,
    }
end

local function getAnnotations(ui)
    local annotations = ui.annotation and ui.annotation.annotations
        or ui.doc_settings:readSetting("annotations")
        or {}
    local copied = {}
    for _, annotation in ipairs(annotations) do
        local item = annotationCopy(annotation)
        if item then
            copied[#copied + 1] = item
        end
    end
    return copied
end

local function annotationId(annotation, page, index)
    return pathHash(table.concat({
        tostring(page),
        tostring(annotation.datetime or index),
        tostring(annotation.color or ""),
        tostring(annotation.text or ""),
        tostring(annotation.note or ""),
    }, "\n"))
end

local function annotationsForTextCompanion(ui)
    local annotations = {}
    for index, annotation in ipairs(getAnnotations(ui)) do
        local page = tonumber(annotation.page)
        if page and page >= 1 then
            annotation.page = page
            annotation.textreflow_id = annotation.textreflow_id
                or annotationId(annotation, page, index)
            annotation.textreflow_source_page = page
            annotation.textreflow_source_pdf = true
            annotations[#annotations + 1] = annotation
        end
    end
    return annotations
end

function TextReflow:init()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function TextReflow:onDispatcherRegisterActions()
    Dispatcher:removeAction("textreflow_toggle_companion")
    Dispatcher:registerAction("textreflow_toggle_companion", {
        category = "none",
        event = "TextReflowToggleCompanion",
        title = _("TextReflow: Toggle PDF / text companion"),
        reader = true,
    })
end

function TextReflow:onTextReflowToggleCompanion()
    local document = self.ui and self.ui.document
    if document and document.is_pdf then
        self:_buildCompanion()
    elseif self:_isCompanion() then
        self:_returnToPdf()
    else
        showMessage(_("TextReflow needs a PDF or a linked text companion."))
    end
    return true
end

function TextReflow:onReaderReady()
    if self.ui and self.ui.document and self.ui.document.is_pdf then
        local pending = self.ui.doc_settings:readSetting(PENDING_ANNOTATIONS_SETTING)
        local page = type(pending) == "table" and tonumber(pending.return_page)
        if page and page >= 1 and page <= self.ui.document:getPageCount() then
            self.ui:handleEvent(Event:new("GotoPage", page))
        end
        self:_syncPendingAnnotations()
    elseif self:_isCompanion() then
        self:_syncPendingPdfAnnotations()
    end
end

function TextReflow:onCloseDocument()
    if self._job then
        self._job.cancelled = true
        UIManager:close(self._job.progress)
        self._job = nil
    end
end

function TextReflow:_forceOcr()
    return self.ui.doc_settings:readSetting(FORCE_OCR_SETTING) == true
end

function TextReflow:_ocrLanguage()
    local language = self.ui.doc_settings:readSetting(OCR_LANGUAGE_SETTING)
    if type(language) == "string" and language ~= "" then
        return language
    end
    local configurable = self.ui.document.configurable
    local document_language = configurable and configurable.doc_language
    return type(document_language) == "string" and document_language ~= ""
        and document_language or "eng"
end

function TextReflow:_pageRange()
    local page_count = self.ui.document:getPageCount()
    local first = tonumber(self.ui.doc_settings:readSetting(OCR_RANGE_START_SETTING)) or 1
    local last = tonumber(self.ui.doc_settings:readSetting(OCR_RANGE_END_SETTING)) or page_count
    first = math.max(1, math.min(page_count, math.floor(first)))
    last = math.max(first, math.min(page_count, math.floor(last)))
    return first, last
end

function TextReflow:_saveRange(first, last)
    local settings = self.ui.doc_settings
    settings:saveSetting(OCR_RANGE_START_SETTING, first)
    settings:saveSetting(OCR_RANGE_END_SETTING, last)
    local ok, err = flushSettings(settings)
    if not ok then
        showMessage(_("Could not save the OCR page range: ") .. tostring(err))
    end
    return ok
end

function TextReflow:_showOcrLanguageMenu()
    local languages = getInstalledOcrLanguages()
    if not languages or #languages == 0 then
        showMessage(_("No installed Tesseract OCR languages were found."))
        return
    end
    local menu
    local items = {}
    for _, language in ipairs(languages) do
        items[#items + 1] = {
            text = language,
            radio = true,
            checked_func = function()
                return self:_ocrLanguage() == language
            end,
            callback = function()
                self.ui.doc_settings:saveSetting(OCR_LANGUAGE_SETTING, language)
                local saved, err = flushSettings(self.ui.doc_settings)
                UIManager:close(menu)
                if saved then
                    showMessage(string.format(
                        _("OCR language set to %s. Re-OCR all pages to replace existing text."),
                        language))
                else
                    showMessage(_("Could not save the OCR language: ") .. tostring(err))
                end
            end,
        }
    end
    menu = Menu:new{
        title = _("Tesseract OCR language"),
        item_table = items,
    }
    UIManager:show(menu)
end

function TextReflow:_showRangeDialog()
    local first, last = self:_pageRange()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("OCR page range"),
        fields = {
            { text = tostring(first), hint = _("First page") },
            { text = tostring(last), hint = _("Last page") },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local new_first = tonumber(fields[1])
                        local new_last = tonumber(fields[2])
                        local page_count = self.ui.document:getPageCount()
                        if not new_first or not new_last
                            or new_first % 1 ~= 0 or new_last % 1 ~= 0
                            or new_first < 1 or new_last > page_count
                            or new_first > new_last then
                            showMessage(string.format(
                                _("Enter a page range from 1 to %d, with the first page no later than the last."),
                                page_count))
                            return
                        end
                        UIManager:close(dialog)
                        if self:_saveRange(new_first, new_last) then
                            showMessage(string.format(
                                _("OCR page range set to %d-%d."), new_first, new_last))
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function TextReflow:_setRangeFirstPage()
    local _, last = self:_pageRange()
    self:_saveRange(1, last)
end

function TextReflow:_setRangeLastPage()
    local first = self:_pageRange()
    self:_saveRange(first, self.ui.document:getPageCount())
end

function TextReflow:_purgePdfData()
    if self._job then
        showMessage(_("Wait for TextReflow to finish before purging this PDF's data."))
        return
    end
    local doc = self.ui and self.ui.document
    if not (doc and doc.is_pdf) then
        showMessage(_("Open a PDF to purge its TextReflow data."))
        return
    end
    local paths, path_error = pathsForPdf(doc.file)
    if not paths then
        showMessage(_("Could not locate this PDF's TextReflow data: ") .. tostring(path_error))
        return
    end

    local settings = self.ui.doc_settings
    for _, key in ipairs({
        FORCE_OCR_SETTING,
        OCR_LANGUAGE_SETTING,
        OCR_RANGE_START_SETTING,
        OCR_RANGE_END_SETTING,
        FAILED_PAGES_SETTING,
        PENDING_ANNOTATIONS_SETTING,
        PENDING_PDF_ANNOTATIONS_SETTING,
        MAPPED_ANNOTATIONS_SETTING,
    }) do
        settings:saveSetting(key, nil)
    end
    local settings_saved, settings_error = flushSettings(settings)
    if not settings_saved then
        showMessage(_("Could not clear this PDF's TextReflow settings: ") .. tostring(settings_error))
        return
    end

    local remove_errors = {}
    local function removeFile(path)
        if lfs.attributes(path, "mode") then
            local removed, err = os.remove(path)
            if not removed then
                remove_errors[#remove_errors + 1] = tostring(err or path)
            end
        end
    end
    for _, path in ipairs({
        paths.cache,
        paths.cache .. ".tmp",
        paths.legacy_cache,
        paths.text,
        paths.text .. ".tmp",
    }) do
        removeFile(path)
    end
    for name in lfs.dir(paths.textreflow_dir) do
        if name ~= "." and name ~= ".."
            and name:match("^" .. paths.document_id .. "%-") then
            removeFile(paths.textreflow_dir .. "/" .. name)
        end
    end

    local companion_sidecar_ok, companion_sidecar = pcall(
        DocSettings.getSidecarDir, DocSettings, paths.text)
    if companion_sidecar_ok and type(companion_sidecar) == "string"
        and companion_sidecar ~= "" and lfs.attributes(companion_sidecar, "mode") == "directory" then
        if type(DocSettings.removeSidecarDir) ~= "function" then
            remove_errors[#remove_errors + 1] = _("KOReader cannot remove the text companion sidecar.")
        else
            local removed, result = pcall(DocSettings.removeSidecarDir, companion_sidecar)
            if not removed or result == false
                or lfs.attributes(companion_sidecar, "mode") == "directory" then
                remove_errors[#remove_errors + 1] = tostring(result
                    or _("The text companion sidecar could not be removed."))
            end
        end
    end
    if #remove_errors > 0 then
        showMessage(_("Some TextReflow files could not be removed: ")
            .. table.concat(remove_errors, "\n"))
        return
    end
    showMessage(_("TextReflow's cache, generated companion, and companion annotations were purged for this PDF."))
end

local function getFailedPages(value)
    local pages = {}
    if type(value) == "table" then
        for _, item in ipairs(value) do
            local page = type(item) == "table" and tonumber(item.page) or tonumber(item)
            if page and page >= 1 then
                pages[page] = type(item) == "table" and item.error
                    or _("A previous recognition attempt failed.")
            end
        end
    end
    return pages
end

function TextReflow:_isCompanion()
    return self.ui and self.ui.doc_settings
        and type(self.ui.doc_settings:readSetting(SOURCE_PDF_SETTING)) == "string"
end

function TextReflow:addToMainMenu(menu_items)
    local document = self.ui and self.ui.document
    if not document then
        return
    end
    local submenu = {}
    if document.is_pdf then
        submenu[#submenu + 1] = {
            text = _("Toggle PDF / text companion (build or open text)"),
            callback = function()
                self:onTextReflowToggleCompanion()
            end,
        }
        submenu[#submenu + 1] = {
            text = _("Retry failed pages"),
            enabled_func = function()
                return next(getFailedPages(
                    self.ui.doc_settings:readSetting(FAILED_PAGES_SETTING))) ~= nil
            end,
            callback = function()
                local failed = getFailedPages(
                    self.ui.doc_settings:readSetting(FAILED_PAGES_SETTING))
                local pages = {}
                for page in pairs(failed) do
                    pages[#pages + 1] = page
                end
                table.sort(pages)
                if #pages == 0 then
                    showMessage(_("There are no failed pages to retry."))
                else
                    self:_buildCompanion{ page_numbers = pages }
                end
            end,
        }
        submenu[#submenu + 1] = {
            text = _("Re-OCR all pages with selected language"),
            callback = function()
                local page_count = document:getPageCount()
                self.ui.doc_settings:saveSetting(FORCE_OCR_SETTING, true)
                if not self:_saveRange(1, page_count) then
                    return
                end
                local saved, err = flushSettings(self.ui.doc_settings)
                if not saved then
                    showMessage(_("Could not save the OCR preference: ") .. tostring(err))
                    return
                end
                self:_buildCompanion{ force_refresh = true, force_ocr = true }
            end,
        }
        submenu[#submenu + 1] = {
            text = _("Purge TextReflow cache and companion data"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Remove this PDF's OCR cache, generated text companion, and companion annotations?"),
                    ok_text = _("Purge"),
                    ok_callback = function()
                        self:_purgePdfData()
                    end,
                })
            end,
        }
        submenu[#submenu + 1] = {
            text_func = function()
                local first, last = self:_pageRange()
                return string.format(_("OCR settings (%s, pages %d-%d)"),
                    self:_ocrLanguage(), first, last)
            end,
            callback = function()
                return nil
            end,
            sub_item_table = {
                {
                    text_func = function()
                        return string.format(_("OCR language: %s"), self:_ocrLanguage())
                    end,
                    callback = function()
                        self:_showOcrLanguageMenu()
                    end,
                },
                {
                    text = _("Set page range"),
                    callback = function()
                        self:_showRangeDialog()
                    end,
                },
                {
                    text = _("Set range start to first page"),
                    callback = function()
                        self:_setRangeFirstPage()
                    end,
                },
                {
                    text = _("Set range end to last page"),
                    callback = function()
                        self:_setRangeLastPage()
                    end,
                },
                {
                    text_func = function()
                        return self:_forceOcr()
                            and _("Force OCR: on")
                            or _("Force OCR: off")
                    end,
                    checked_func = function()
                        return self:_forceOcr()
                    end,
                    callback = function()
                        local enabled = not self:_forceOcr()
                        self.ui.doc_settings:saveSetting(FORCE_OCR_SETTING, enabled)
                        local ok, err = flushSettings(self.ui.doc_settings)
                        if not ok then
                            showMessage(_("Could not save the OCR preference: ") .. tostring(err))
                        else
                            showMessage(enabled
                                and _("Forced OCR is enabled for the next text build.")
                                or _("Forced OCR is disabled. KOReader will still OCR pages without a text layer."))
                        end
                    end,
                },
            },
        }
    elseif self:_isCompanion() then
        submenu[#submenu + 1] = {
            text = _("Toggle PDF / text companion (return to PDF)"),
            callback = function()
                self:onTextReflowToggleCompanion()
            end,
        }
    else
        return
    end
    menu_items.textreflow = {
        text = _("TextReflow"),
        sorting_hint = "typeset",
        sub_item_table = submenu,
    }
end

function TextReflow:_buildCompanion(options)
    options = options or {}
    local ui = self.ui
    local doc = ui and ui.document
    if not (doc and doc.is_pdf) then
        showMessage(_("TextReflow works with PDF documents."))
        return
    end
    if self._job then
        showMessage(_("Text extraction is already running."))
        return
    end

    local paths, path_error = pathsForPdf(doc.file)
    if not paths then
        showMessage(_("Could not create the TextReflow cache: ") .. tostring(path_error))
        return
    end
    local cached, cache_error = readPdfPageCache(paths)
    if not cached then
        showMessage(_("Could not read the TextReflow cache: ") .. tostring(cache_error))
        return
    end
    if cache_error then
        logger.warn("TextReflow cache recovery:", cache_error)
    end

    local page_count = doc:getPageCount()
    local language = self:_ocrLanguage()
    local installed_languages = getInstalledOcrLanguages()
    local force_ocr = options.force_ocr == true
        or self:_forceOcr()
        or (doc.configurable and doc.configurable.forced_ocr == 1)
    if force_ocr and (not installed_languages or #installed_languages == 0) then
        showMessage(_("Forced OCR cannot run because no installed Tesseract languages were found."))
        return
    end
    if installed_languages and #installed_languages > 0 then
        local language_installed = false
        for _, installed in ipairs(installed_languages) do
            if installed == language then
                language_installed = true
                break
            end
        end
        if not language_installed then
            local fallback_language
            local configurable = doc.configurable
            local document_language = configurable and configurable.doc_language
            for _, installed in ipairs(installed_languages) do
                if installed == document_language then
                    fallback_language = installed
                    break
                end
            end
            language = fallback_language or installed_languages[1]
            self.ui.doc_settings:saveSetting(OCR_LANGUAGE_SETTING, language)
            local language_saved, language_error = flushSettings(self.ui.doc_settings)
            if not language_saved then
                logger.warn("TextReflow could not save the fallback OCR language:", language_error)
                showMessage(_("Could not save the fallback OCR language: ") .. tostring(language_error))
            end
            showMessage(string.format(
                _("The saved OCR language is no longer installed. Using %s instead."),
                language))
        end
    end
    local first_page, last_page = self:_pageRange()
    local order = {}
    if options.page_numbers then
        for _, page in ipairs(options.page_numbers) do
            page = math.floor(tonumber(page) or 0)
            if page >= 1 and page <= page_count then
                order[#order + 1] = page
            end
        end
    else
        for page = first_page, last_page do
            order[#order + 1] = page
        end
    end
    if #order == 0 then
        showMessage(_("There are no pages in the selected OCR range."))
        return
    end
    if not options.page_numbers then
        local current_page = math.max(1, math.min(page_count, ui:getCurrentPage() or 1))
        for index, page in ipairs(order) do
            if page == current_page then
                table.remove(order, index)
                table.insert(order, 1, current_page)
                break
            end
        end
    end

    local job = {
        doc = doc,
        ui = ui,
        source = doc.file,
        paths = paths,
        pages = cached,
        order = order,
        page_index = 1,
        force_ocr = force_ocr or false,
        language = language,
        failures = getFailedPages(ui.doc_settings:readSetting(FAILED_PAGES_SETTING)),
        progress = ProgressDialog:new{},
        cancelled = false,
    }
    if options.page_numbers then
        for _, page in ipairs(order) do
            job.failures[page] = nil
        end
    end
    self._job = job
    job.progress:show()

    local function failuresAsList()
        local result = {}
        for page, message in pairs(job.failures) do
            result[#result + 1] = { page = page, error = message }
        end
        table.sort(result, function(left, right) return left.page < right.page end)
        return result
    end

    local function finish()
        if self._job ~= job then
            return
        end
        self._job = nil
        UIManager:close(job.progress)
        if job.cancelled or self.ui ~= ui or ui.document ~= doc then
            return
        end
        local cache_ok, cache_write_error = writePageCache(
            paths.cache, job.pages, page_count)
        ui.doc_settings:saveSetting(FAILED_PAGES_SETTING, failuresAsList())
        local failure_save_ok, failure_save_error = flushSettings(ui.doc_settings)
        local generated_page = 0
        local write_ok, write_error = writeTextChunks(paths.text, function()
            generated_page = generated_page + 1
            if generated_page > page_count then
                return nil
            end
            local page = generated_page
            local record = job.pages[page]
            local reason = job.failures[page]
            local chunk
            if reason and record and type(record.text) == "string" then
                local previous_language = record.language or _("unknown")
                chunk = string.format(
                    "--- PDF page %d ---\n\n[TextReflow: recognition failed: %s. Previous cached text (%s) follows.]\n\n%s",
                    page,
                    tostring(reason):gsub("[\r\n]+", " "),
                    previous_language,
                    record.text)
            elseif record and type(record.text) == "string" then
                chunk = string.format(
                    "--- PDF page %d ---\n\n%s", page, record.text)
            else
                local placeholder = reason
                    and string.format("[TextReflow: OCR failed: %s]", tostring(reason):gsub("[\r\n]+", " "))
                    or "[TextReflow: page was not processed; select it in the OCR page range to recognize it.]"
                chunk = string.format(
                    "--- PDF page %d ---\n\n%s", page, placeholder)
            end
            return (page > 1 and "\n\n" or "") .. chunk
        end)
        if not write_ok then
            showMessage(_("Could not write the text companion: ") .. tostring(write_error))
            return
        end
        local companion_settings = DocSettings:open(paths.text)
        companion_settings:saveSetting(SOURCE_PDF_SETTING, job.source)
        companion_settings:saveSetting(SOURCE_FORCE_OCR_SETTING, job.force_ocr)
        companion_settings:saveSetting(SOURCE_OCR_LANGUAGE_SETTING, job.language)
        companion_settings:saveSetting(
            PENDING_PDF_ANNOTATIONS_SETTING,
            {
                source = job.source,
                annotations = annotationsForTextCompanion(ui),
            })
        local settings_ok, settings_error = flushSettings(companion_settings)
        if not settings_ok then
            showMessage(_("Could not save the text companion link: ") .. tostring(settings_error))
            return
        end
        require("apps/reader/readerui"):showReader(paths.text)
        local failures = failuresAsList()
        if #failures > 0 then
            local message = string.format(
                _("Text companion created with %d failed page(s). Use Retry failed pages from the PDF menu."),
                #failures)
            if not cache_ok or not failure_save_ok then
                message = message .. "\n\n"
                    .. _("Some progress data could not be saved: ")
                    .. tostring(cache_write_error or failure_save_error)
            end
            showMessage(message)
        elseif not cache_ok or not failure_save_ok then
            showMessage(_("The text companion was created, but some progress data could not be saved: ")
                .. tostring(cache_write_error or failure_save_error))
        end
    end

    local function extractNextPage()
        if self._job ~= job or self.ui ~= ui or ui.document ~= doc then
            return
        end
        local page = job.order[job.page_index]
        if not page then
            finish()
            return
        end
        job.progress:update(job.page_index - 1, #job.order, page)
        local cached_page = job.pages[page]
        if not options.force_refresh and cached_page
            and cached_page.force_ocr == job.force_ocr
            and cached_page.language == job.language then
            job.failures[page] = nil
            job.page_index = job.page_index + 1
            job.progress:update(job.page_index - 1, #job.order, page)
            UIManager:scheduleIn(0.01, extractNextPage)
            return
        end
        local text, _, extraction_error = extractPage(
            doc, page, job.force_ocr, job.language)
        if not text or text:match("^%s*$") then
            job.failures[page] = extraction_error or _("No text was recognized.")
        else
            local saved, save_error = appendPageCache(
                paths.cache, page, text, job.force_ocr, job.language)
            job.pages[page] = {
                page = page,
                text = text,
                force_ocr = job.force_ocr,
                language = job.language,
            }
            job.failures[page] = nil
            if not saved then
                logger.warn("TextReflow could not append OCR cache record", page, save_error)
            end
        end
        job.progress:update(job.page_index, #job.order, page)
        job.page_index = job.page_index + 1
        UIManager:scheduleIn(0.01, extractNextPage)
    end

    UIManager:scheduleIn(0.01, extractNextPage)
end

function TextReflow:_returnToPdf()
    local ui = self.ui
    local settings = ui and ui.doc_settings
    local source = settings and settings:readSetting(SOURCE_PDF_SETTING)
    if type(source) ~= "string" or source == "" then
        showMessage(_("This text document has no linked source PDF."))
        return
    end
    if lfs.attributes(source, "mode") ~= "file" then
        showMessage(_("The source PDF could not be found: ") .. source)
        return
    end

    local return_page
    local return_warning
    local paths, path_error = pathsForPdf(source)
    if paths then
        local cache, cache_error = readPdfPageCache(paths)
        if cache then
            return_page = findVisibleSourcePage(ui, cache)
            return_warning = cache_error
        else
            return_warning = _("The cached page map could not be read; the PDF will reopen at its previous position.")
                .. " " .. tostring(cache_error)
        end
    else
        return_warning = _("The cached page map is unavailable; the PDF will reopen at its previous position.")
            .. " " .. tostring(path_error)
    end
    if not return_page then
        local fallback_warning = _("The current TXT position could not be matched to a PDF page; the PDF will reopen at its previous position.")
        return_warning = return_warning
            and (return_warning .. "\n\n" .. fallback_warning)
            or fallback_warning
    end

    local pending = DocSettings:open(source)
    pending:saveSetting(PENDING_ANNOTATIONS_SETTING, {
        annotations = getAnnotations(ui),
        force_ocr = settings:readSetting(SOURCE_FORCE_OCR_SETTING) == true,
        language = settings:readSetting(SOURCE_OCR_LANGUAGE_SETTING),
        return_page = return_page,
        return_warning = return_warning,
    })
    local ok, err = flushSettings(pending)
    if not ok then
        showMessage(_("Could not queue annotations for the source PDF: ") .. tostring(err))
        return
    end
    require("apps/reader/readerui"):showReader(source)
end

function TextReflow:_syncPendingPdfAnnotations()
    local ui = self.ui
    local doc = ui and ui.document
    local settings = ui and ui.doc_settings
    if not (doc and settings and ui.annotation) then
        return
    end
    local pending = settings:readSetting(PENDING_PDF_ANNOTATIONS_SETTING)
    if type(pending) ~= "table" or type(pending.annotations) ~= "table" then
        return
    end
    if type(doc.findText) ~= "function" then
        showMessage(_("This text document cannot search for PDF annotation text."))
        return
    end
    local current_source = settings:readSetting(SOURCE_PDF_SETTING)
    if pending.source ~= current_source then
        showMessage(_("The queued PDF annotations belong to a different source document."))
        return
    end

    local current_ids = {}
    for _, annotation in ipairs(pending.annotations) do
        if type(annotation.textreflow_id) == "string" then
            current_ids[annotation.textreflow_id] = true
        end
    end
    local stale_indices = {}
    for index, annotation in ipairs(ui.annotation.annotations or {}) do
        if annotation.textreflow_source_pdf
            and annotation.textreflow_id
            and not current_ids[annotation.textreflow_id] then
            stale_indices[#stale_indices + 1] = index
        end
    end
    if #stale_indices > 0 and not (ui.bookmark and ui.bookmark.removeItemByIndex) then
        showMessage(_("Could not remove PDF annotations that were deleted from the source PDF."))
        return
    end
    for index = #stale_indices, 1, -1 do
        local removed, remove_error = pcall(
            ui.bookmark.removeItemByIndex, ui.bookmark, stale_indices[index])
        if not removed then
            showMessage(_("Could not remove a deleted PDF annotation from the text companion: ")
                .. tostring(remove_error))
            return
        end
    end

    local added, skipped, already_synced = 0, 0, 0
    for _, annotation in ipairs(pending.annotations) do
        local text = type(annotation.text) == "string" and annotation.text or ""
        if text == "" then
            skipped = skipped + 1
        else
            local search_text = text:gsub("%s+", " "):match("^%s*(.-)%s*$")
            local search_ok, matches
            if search_text ~= "" then
                search_ok, matches = pcall(
                    doc.findText, doc, search_text, 0, 0, true, nil, false, 2)
            end
            if not search_ok or type(matches) ~= "table" then
                skipped = skipped + 1
            else
                local match
                if matches.start and matches["end"] then
                    match = matches
                elseif #matches == 1 then
                    match = matches[1]
                end
                if not match or type(match.start) ~= "string"
                    or type(match["end"]) ~= "string" then
                    skipped = skipped + 1
                else
                    local id = annotation.textreflow_id
                    local existing
                    for _, saved in ipairs(ui.annotation.annotations or {}) do
                        if id and saved.textreflow_id == id then
                            existing = true
                            break
                        end
                    end
                    if existing then
                        already_synced = already_synced + 1
                    else
                        local item = {
                            pos0 = match.start,
                            pos1 = match["end"],
                            page = doc:getPageFromXPointer(match.start),
                            text = text,
                            note = annotation.note,
                            color = annotation.color or "yellow",
                            drawer = annotation.drawer or "lighten",
                            datetime = annotation.datetime,
                            chapter = annotation.chapter,
                            textreflow_id = id,
                            textreflow_source_page = annotation.page,
                            textreflow_source_pdf = true,
                        }
                        local item_index = ui.annotation:addItem(item)
                        ui:handleEvent(Event:new("AnnotationsModified", {
                            item,
                            nb_highlights_added = 1,
                            index_modified = item_index,
                        }))
                        added = added + 1
                    end
                end
            end
        end
    end

    settings:saveSetting(PENDING_PDF_ANNOTATIONS_SETTING, nil)
    local saved, save_error = flushSettings(settings)
    if not saved then
        showMessage(_("Could not clear the pending PDF annotations: ") .. tostring(save_error))
        return
    end
    if added > 0 or skipped > 0 or already_synced > 0 then
        showMessage(string.format(
            _("TextReflow copied %d PDF annotation(s) to the text companion; %d were already synced; %d could not be matched uniquely."),
            added, already_synced, skipped))
    end
end

function TextReflow:_syncPendingAnnotations()
    local ui = self.ui
    local doc = ui and ui.document
    local settings = ui and ui.doc_settings
    if not (doc and doc.is_pdf and settings and ui.annotation) then
        return
    end
    local pending = settings:readSetting(PENDING_ANNOTATIONS_SETTING)
    if type(pending) ~= "table" or type(pending.annotations) ~= "table" then
        return
    end
    local paths, path_error = pathsForPdf(doc.file)
    if not paths then
        showMessage(_("Could not access the TextReflow cache: ") .. tostring(path_error))
        return
    end
    local cache, cache_error = readPdfPageCache(paths)
    if not cache then
        showMessage(_("Could not read the TextReflow cache: ") .. tostring(cache_error))
        return
    end
    if cache_error then
        logger.warn("TextReflow annotation cache recovery:", cache_error)
    end

    local mapped_ids = settings:readSetting(MAPPED_ANNOTATIONS_SETTING)
    if type(mapped_ids) ~= "table" then
        mapped_ids = {}
    end
    local added, skipped, already_synced = 0, 0, 0
    for index, annotation in ipairs(pending.annotations) do
        local selection = tokensFromText(annotation.text)
        local expected_page = tonumber(annotation.textreflow_source_page)
        local candidate_page, candidate_count
        candidate_count = 0
        for page, record in pairs(cache) do
            if not expected_page or page == expected_page then
                local page_tokens = tokensFromText(record.text)
                local _, occurrences = findUniqueSequence(page_tokens, selection)
                if occurrences > 0 then
                    candidate_page = page
                    candidate_count = candidate_count + occurrences
                end
            end
        end
        if candidate_count ~= 1 then
            skipped = skipped + 1
        else
            local page_record = cache[candidate_page]
            local force_ocr = pending.force_ocr == true
            local language = pending.language
            if page_record then
                force_ocr = page_record.force_ocr
                language = page_record.language
            end
            local text, words, extraction_error = extractPage(
                doc,
                candidate_page,
                force_ocr,
                language)
            if not text then
                skipped = skipped + 1
                logger.warn("TextReflow could not extract PDF page", candidate_page, extraction_error)
            else
                local word_tokens, matched_words = {}, {}
                for _, word in ipairs(words) do
                    local normalized = normalizeWord(word.word)
                    if normalized ~= "" then
                        word_tokens[#word_tokens + 1] = normalized
                        matched_words[#matched_words + 1] = word
                    end
                end
                local start_index, occurrences = findUniqueSequence(word_tokens, selection)
                if not start_index or occurrences ~= 1 then
                    skipped = skipped + 1
                else
                    local end_index = start_index + #selection - 1
                    local first, last = matched_words[start_index], matched_words[end_index]
                    local id = annotation.textreflow_id
                        or annotationId(annotation, candidate_page, index)
                    local already_present = false
                    for _, saved in ipairs(ui.annotation.annotations or {}) do
                        local saved_page = saved.page
                            or (type(saved.pos0) == "table" and saved.pos0.page)
                        if saved_page == candidate_page
                            and saved.text == annotation.text
                            and (saved.note or "") == (annotation.note or "") then
                            already_present = true
                            break
                        end
                    end
                    if mapped_ids[id] or already_present then
                        mapped_ids[id] = true
                        already_synced = already_synced + 1
                    elseif annotation.textreflow_source_pdf then
                        skipped = skipped + 1
                    else
                        local pboxes, valid_boxes = {}, true
                        for word_index = start_index, end_index do
                            local word = matched_words[word_index]
                            if word.x0 and word.y0 and word.x1 and word.y1
                                and word.x1 > word.x0 and word.y1 > word.y0 then
                                pboxes[#pboxes + 1] = {
                                    x = word.x0,
                                    y = word.y0,
                                    w = word.x1 - word.x0,
                                    h = word.y1 - word.y0,
                                }
                            else
                                valid_boxes = false
                            end
                        end
                        if not valid_boxes or #pboxes ~= #selection
                            or not (first.x0 and first.y0 and first.x1 and first.y1
                                and last.x0 and last.y0 and last.x1 and last.y1) then
                            skipped = skipped + 1
                        else
                            local item = {
                                page = candidate_page,
                                pos0 = {
                                    page = candidate_page,
                                    x = (first.x0 + first.x1) / 2,
                                    y = (first.y0 + first.y1) / 2,
                                },
                                pos1 = {
                                    page = candidate_page,
                                    x = (last.x0 + last.x1) / 2,
                                    y = (last.y0 + last.y1) / 2,
                                },
                                pboxes = pboxes,
                                text = annotation.text,
                                note = annotation.note,
                                color = annotation.color or "yellow",
                                drawer = annotation.drawer or "lighten",
                                datetime = annotation.datetime,
                                chapter = annotation.chapter,
                                textreflow_id = id,
                            }
                            local existing
                            for _, saved in ipairs(ui.annotation.annotations or {}) do
                                if saved.textreflow_id == id then
                                    existing = true
                                    break
                                end
                            end
                            if existing then
                                mapped_ids[id] = true
                                already_synced = already_synced + 1
                            else
                                local item_index = ui.annotation:addItem(item)
                                ui:handleEvent(Event:new("AnnotationsModified", {
                                    item,
                                    nb_highlights_added = 1,
                                    index_modified = item_index,
                                }))
                                mapped_ids[id] = true
                                settings:saveSetting(MAPPED_ANNOTATIONS_SETTING, mapped_ids)
                                local saved, save_error = flushSettings(settings)
                                if not saved then
                                    logger.warn("TextReflow could not save mapped annotation:", save_error)
                                    showMessage(_("Could not save a mapped annotation: ") .. tostring(save_error))
                                    return
                                end
                                added = added + 1
                            end
                        end
                    end
                end
            end
        end
    end

    settings:saveSetting(PENDING_ANNOTATIONS_SETTING, nil)
    local saved, save_error = flushSettings(settings)
    if not saved then
        showMessage(_("Could not clear the pending TextReflow annotations: ") .. tostring(save_error))
        return
    end
    local messages = {}
    if added > 0 or skipped > 0 or already_synced > 0 then
        messages[#messages + 1] = string.format(
            _("TextReflow added %d annotation(s) to the PDF; %d were already synced; %d could not be mapped uniquely and remain in the TXT companion."),
            added, already_synced, skipped)
    end
    if type(pending.return_warning) == "string" then
        messages[#messages + 1] = pending.return_warning
    end
    if #messages > 0 then
        showMessage(table.concat(messages, "\n\n"))
    end
end

return TextReflow
