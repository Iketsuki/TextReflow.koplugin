local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local Event = require("ui/event")
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
    local attributes = lfs.attributes(pdf_path) or {}
    local identity = table.concat({
        pdf_path,
        tostring(attributes.size or ""),
        tostring(attributes.modification or ""),
    }, "\n")
    local stem = CACHE_DIR .. "/" .. pathHash(identity)
    return {
        text = stem .. ".txt",
        cache = stem .. ".jsonl",
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

local function writePageCache(path, pages, page_count)
    local records = {}
    for page = 1, page_count do
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
            records[#records + 1] = encoded
        end
    end
    return writeTextFile(path, table.concat(records, "\n") .. "\n")
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
    local old_wrap = configurable.text_wrap
    local old_forced_ocr = configurable.forced_ocr
    local old_language = configurable.doc_language
    configurable.text_wrap = 0
    configurable.doc_language = language or old_language
    if force_ocr then
        configurable.forced_ocr = 1
    end
    local ok, text_boxes = pcall(doc.getTextBoxes, doc, page_number)
    configurable.text_wrap = old_wrap
    configurable.forced_ocr = old_forced_ocr
    configurable.doc_language = old_language
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

function TextReflow:init()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function TextReflow:onDispatcherRegisterActions()
    Dispatcher:registerAction("textreflow_toggle_companion", {
        category = "none",
        event = "TextReflowToggleCompanion",
        title = _("TextReflow: toggle PDF and text companion"),
        reader = true,
    })
    Dispatcher:registerAction("textreflow_extract_companion", {
        category = "none",
        event = "TextReflowExtractCompanion",
        title = _("TextReflow: extract PDF text"),
        reader = true,
    })
end

function TextReflow:onTextReflowToggleCompanion()
    if self.ui and self.ui.document and self.ui.document.is_pdf then
        self:_buildCompanion()
    elseif self:_isCompanion() then
        self:_returnToPdf()
    else
        showMessage(_("TextReflow works with PDF documents and their linked text companions."))
    end
    return true
end

function TextReflow:onTextReflowExtractCompanion()
    if self.ui and self.ui.document and self.ui.document.is_pdf then
        self:_buildCompanion()
    else
        showMessage(_("Text extraction can only be started from a PDF."))
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
    local document_language = self.ui.document.configurable.doc_language
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
    local ok, languages = pcall(function()
        return require("ui/data/ocr").getOCRLangs()
    end)
    if not ok or type(languages) ~= "table" or #languages == 0 then
        if not ok then
            logger.warn("TextReflow could not list installed OCR languages:", languages)
        end
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
            text = _("Toggle to text companion (extract if needed)"),
            help_text = _("Open the linked reflowable text companion, creating or updating it if needed."),
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
            text = _("Toggle back to PDF and sync highlights"),
            callback = function()
                self:onTextReflowToggleCompanion()
            end,
        }
    else
        return
    end
    menu_items.textreflow = {
        text = _("TextReflow"),
        sorting_hint = "document",
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
    local cached, cache_error = readPageCache(paths.cache)
    if not cached then
        showMessage(_("Could not read the TextReflow cache: ") .. tostring(cache_error))
        return
    end
    if cache_error then
        logger.warn("TextReflow cache recovery:", cache_error)
    end

    local page_count = doc:getPageCount()
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
        force_ocr = options.force_ocr == true
            or self:_forceOcr() or doc.configurable.forced_ocr == 1,
        language = self:_ocrLanguage(),
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
        local chunks = {}
        for page = 1, page_count do
            local record = job.pages[page]
            local reason = job.failures[page]
            if reason and record and type(record.text) == "string" then
                local previous_language = record.language or _("unknown")
                chunks[#chunks + 1] = string.format(
                    "--- PDF page %d ---\n\n[TextReflow: recognition failed: %s. Previous cached text (%s) follows.]\n\n%s",
                    page,
                    tostring(reason):gsub("[\r\n]+", " "),
                    previous_language,
                    record.text)
            elseif record and type(record.text) == "string" then
                chunks[#chunks + 1] = string.format(
                    "--- PDF page %d ---\n\n%s", page, record.text)
            else
                local placeholder = reason
                    and string.format("[TextReflow: OCR failed: %s]", tostring(reason):gsub("[\r\n]+", " "))
                    or "[TextReflow: page was not processed; select it in the OCR page range to recognize it.]"
                chunks[#chunks + 1] = string.format(
                    "--- PDF page %d ---\n\n%s", page, placeholder)
            end
        end
        local write_ok, write_error = writeTextFile(paths.text, table.concat(chunks, "\n\n"))
        if not write_ok then
            showMessage(_("Could not write the text companion: ") .. tostring(write_error))
            return
        end
        local companion_settings = DocSettings:open(paths.text)
        companion_settings:saveSetting(SOURCE_PDF_SETTING, job.source)
        companion_settings:saveSetting(SOURCE_FORCE_OCR_SETTING, job.force_ocr)
        companion_settings:saveSetting(SOURCE_OCR_LANGUAGE_SETTING, job.language)
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
        local cache, cache_error = readPageCache(paths.cache)
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
    local cache, cache_error = readPageCache(paths.cache)
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
        local candidate_page, candidate_count
        candidate_count = 0
        for page, record in pairs(cache) do
            local page_tokens = tokensFromText(record.text)
            local _, occurrences = findUniqueSequence(page_tokens, selection)
            if occurrences > 0 then
                candidate_page = page
                candidate_count = candidate_count + occurrences
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
                    local id = annotationId(annotation, candidate_page, index)
                    if mapped_ids[id] then
                        already_synced = already_synced + 1
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
