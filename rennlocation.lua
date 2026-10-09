-- RennHSG Location Manager v2. Uses the existing Teleport code and device binding.
-- Publish this standalone source as rennlocation.lua beside KraRenn.lua.
local environment = (type(getgenv) == "function" and getgenv()) or _G
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer
while not player do task.wait(); player = Players.LocalPlayer end
local requestFn = request or http_request or (syn and syn.request) or (http and http.request)
    or (fluxus and fluxus.request) or environment.request or environment.http_request
assert(type(requestFn) == "function", "RennHSG: executor memerlukan request/http_request.")
local function post(path, payload)
    local response = requestFn({Url = "https://rennhsg.my.id" .. path, Method = "POST",
        Headers = {["Content-Type"] = "application/json"}, Timeout = 12, Body = HttpService:JSONEncode(payload)})
    assert(type(response) == "table", "Respons website kosong. Coba lagi.")
    local ok, result = pcall(HttpService.JSONDecode, HttpService, response.Body or response.body or "")
    assert(ok and type(result) == "table", "Respons website tidak valid. Coba lagi.")
    return result
end
local function fileFunction(name)
    local value = environment[name] or rawget(_G, name)
    return type(value) == "function" and value or nil
end
local filename = "RennHSG/teleport-" .. tostring(player.UserId) .. ".json"
environment.RENNHSG_ACCESS_CACHE = type(environment.RENNHSG_ACCESS_CACHE) == "table" and environment.RENNHSG_ACCESS_CACHE or {}
local cache = environment.RENNHSG_ACCESS_CACHE[filename]
if type(cache) ~= "table" then
    local read = fileFunction("readfile")
    if read then
        local ok, raw = pcall(read, filename)
        if ok and type(raw) == "string" then
            local decoded, value = pcall(HttpService.JSONDecode, HttpService, raw)
            if decoded and type(value) == "table" then cache = value end
        end
    end
end
cache = type(cache) == "table" and cache or {}
local code = tostring(environment.RENNHSG_TELEPORT_CODE or ""):match("^%s*(.-)%s*$")
environment.RENNHSG_TELEPORT_CODE = nil
local activation
if code ~= "" then
    cache.device_id = type(cache.device_id) == "string" and cache.device_id or HttpService:GenerateGUID(false)
    activation = post("/api/activate.php", {account_code = code, feature = "teleport", device_id = cache.device_id,
        user_id = player.UserId, username = player.Name, label = player.DisplayName})
else
    assert(type(cache.binding_id) == "string" and type(cache.binding_token) == "string",
        "RennHSG: jalankan loader Teleport akun terlebih dahulu, atau salin loader Pengelola Lokasi dari website. Tidak ada key Lokasi terpisah.")
    activation = post("/api/activate.php", {feature = "teleport", binding_id = cache.binding_id,
        binding_token = cache.binding_token, user_id = player.UserId})
end
assert(activation.ok == true, "RennHSG: " .. tostring(activation.error or "Akses Teleport ditolak."))
cache.binding_id = activation.binding_id or cache.binding_id
cache.binding_token = activation.binding_token or cache.binding_token
environment.RENNHSG_ACCESS_CACHE[filename] = cache
local makeFolder, writeFile = fileFunction("makefolder"), fileFunction("writefile")
if makeFolder then pcall(makeFolder, "RennHSG") end
if writeFile then pcall(writeFile, filename, HttpService:JSONEncode({device_id = cache.device_id, binding_id = cache.binding_id, binding_token = cache.binding_token})) end

local previous = environment.RennHSGLocations
if type(previous) == "table" and type(previous.cleanup) == "function" then pcall(previous.cleanup) end
local state = {destroyed = false, authorized = true, busy = false, locations = {}, connections = {}, activePane = "list", minimized = false}
environment.RennHSGLocations = state
local screen, panel, titleBar, body, footer, tabs, left, right, list, searchInput, nameInput
local statusLabel, countLabel, editorTitle, editorHelp, coordinateLabel, saveButton, deleteButton, captureButton, refreshButton, newButton, minimizeButton
local listTab, editorTab, scale
local render, layout, selectLocation, newLocation, refresh
local colors = {background = Color3.fromRGB(15,18,19), paper = Color3.fromRGB(22,26,28), raised = Color3.fromRGB(28,33,35),
    line = Color3.fromRGB(42,50,49), text = Color3.fromRGB(237,241,236), muted = Color3.fromRGB(142,154,147),
    accent = Color3.fromRGB(195,239,115), accentSoft = Color3.fromRGB(39,49,36), danger = Color3.fromRGB(237,139,142)}
local controls = {}
local function connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(state.connections, connection)
    return connection
end
local function create(kind, properties, parent)
    local object = Instance.new(kind)
    for key, value in pairs(properties) do object[key] = value end
    object.Parent = parent
    return object
end
local function rounded(object, radius)
    create("UICorner", {CornerRadius = UDim.new(0, radius or 8)}, object)
end
local function outline(object)
    create("UIStroke", {Color = colors.line, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, object)
end
local function label(text, size, position, parent, fontSize, color)
    return create("TextLabel", {Text = text, Size = size, Position = position, BackgroundTransparency = 1,
        Font = Enum.Font.Gotham, TextSize = fontSize or 12, TextColor3 = color or colors.text,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center}, parent)
end
local function button(text, size, position, parent, primary)
    local object = create("TextButton", {Text = text, Size = size, Position = position, BackgroundColor3 = primary and colors.accent or colors.raised,
        TextColor3 = primary and colors.background or colors.text, Font = Enum.Font.GothamBold, TextSize = 12,
        BorderSizePixel = 0, AutoButtonColor = true}, parent)
    rounded(object, 7); outline(object)
    return object
end
local function input(placeholder, size, position, parent)
    local object = create("TextBox", {PlaceholderText = placeholder, Text = "", Size = size, Position = position,
        BackgroundColor3 = colors.raised, TextColor3 = colors.text, PlaceholderColor3 = colors.muted,
        Font = Enum.Font.Gotham, TextSize = 12, ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left, BorderSizePixel = 0}, parent)
    rounded(object, 7); outline(object)
    create("UIPadding", {PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10)}, object)
    return object
end
local function status(message, failed)
    if state.destroyed or not statusLabel then return end
    statusLabel.Text = tostring(message):gsub("^.-:%d+: ", "")
    statusLabel.TextColor3 = failed and colors.danger or colors.muted
end
local function updateControls()
    for _, control in ipairs(controls) do
        local enabled = state.authorized and not state.busy
        if control == saveButton then enabled = enabled and not state.stale and state.cframe ~= nil end
        if control == deleteButton then enabled = enabled and state.selected ~= nil and not state.stale end
        control.Active = enabled
        control.AutoButtonColor = enabled
        control.TextTransparency = enabled and 0 or 0.55
    end
    nameInput.TextEditable = not state.busy and state.authorized
    saveButton.Text = state.busy and "Memproses..." or (state.selected and "Simpan perubahan" or "Tambah ke website")
end
state.cleanup = function()
    if state.destroyed then return end
    state.destroyed = true
    for _, connection in ipairs(state.connections) do connection:Disconnect() end
    state.connections = {}
    if screen then screen:Destroy() end
    if environment.RennHSGLocations == state then environment.RennHSGLocations = nil end
end
local function call(action, fields)
    assert(state.authorized, "Akses Teleport dicabut. Salin loader terbaru dari website.")
    local payload = {binding_id = cache.binding_id, binding_token = cache.binding_token, user_id = player.UserId, action = action}
    for key, value in pairs(fields or {}) do payload[key] = value end
    local result = post("/api/locations.php", payload)
    if state.destroyed then error("GUI ditutup.") end
    if result.ok ~= true then
        if result.code == "binding_revoked" or result.code == "binding_required" or result.code == "license_inactive"
            or result.code == "wrong_feature" or result.code == "binding_identity" then state.authorized = false end
        if result.code == "location_changed" or result.code == "location_not_found" then
            state.stale = true
            if type(result.locations) == "table" then state.locations = result.locations; render() end
        end
        error(tostring(result.error or "Permintaan lokasi gagal."))
    end
    return result
end
local function perform(work)
    if state.destroyed or state.busy or not state.authorized then return end
    state.busy = true; updateControls()
    task.spawn(function()
        local ok, err = pcall(work)
        if not state.destroyed then
            state.busy = false
            updateControls()
            if not ok then status(err, true) end
        end
    end)
end
local function takePosition()
    local listener = environment.RennHSGListener
    assert(type(listener) ~= "table" or not (listener.teleporting or listener.activeCommand), "Tunggu teleport selesai sebelum mengambil posisi.")
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    assert(root and humanoid and humanoid.Health > 0, "Karakter belum siap. Tunggu respawn.")
    return {root.CFrame:GetComponents()}
end
local function displayCoordinates()
    if not state.cframe then coordinateLabel.Text = "Posisi belum diambil"; return end
    coordinateLabel.Text = string.format("X  %.1f\nY  %.1f\nZ  %.1f", state.cframe[1], state.cframe[2], state.cframe[3])
end
selectLocation = function(item)
    if state.busy then return end
    state.selected, state.stale, state.pendingMutation = item, false, nil
    state.cframe = {table.unpack(item.cframe)}
    nameInput.Text = tostring(item.name)
    editorTitle.Text = "EDIT LOKASI"
    editorHelp.Text = "Ubah nama, atau ambil posisi baru untuk mengganti koordinat."
    deleteButton.Visible = true
    saveButton.Size = UDim2.new(1, -102, 0, 36)
    state.activePane = "editor"
    displayCoordinates(); render(); layout(); updateControls()
    status("Dipilih: " .. tostring(item.name))
end
newLocation = function()
    if state.busy then return end
    state.selected, state.stale, state.pendingMutation = nil, false, nil
    nameInput.Text = ""
    local ok, values = pcall(takePosition)
    state.cframe = ok and values or nil
    editorTitle.Text = "TAMBAH LOKASI"
    editorHelp.Text = "Beri nama dan simpan posisi karakter ke website."
    deleteButton.Visible = false
    saveButton.Size = UDim2.new(1, 0, 0, 36)
    state.activePane = "editor"
    displayCoordinates(); render(); layout(); updateControls()
    status(ok and "Posisi karakter diambil. Isi nama, lalu simpan." or values, not ok)
end
refresh = function(quiet)
    local result = call("list")
    assert(type(result.locations) == "table", "Daftar lokasi tidak valid.")
    state.locations = result.locations
    if state.selected then
        local current
        for _, item in ipairs(state.locations) do if item.id == state.selected.id then current = item; break end end
        if not current or current.revision ~= state.selected.revision then
            state.stale = true
            status("Lokasi pilihan berubah. Pilih kembali dari daftar sebelum menyimpan.", true)
        end
    end
    render()
    if not quiet and not state.stale then status(tostring(#state.locations) .. " lokasi tersedia. Akses memakai Teleport.") end
end
local function saveLocation()
    if state.stale then status("Pilih ulang lokasi dari daftar terlebih dahulu.", true); return end
    perform(function()
        local name = nameInput.Text:match("^%s*(.-)%s*$")
        assert(name ~= "" and #name <= 100, "Isi nama lokasi, maksimal 100 byte.")
        assert(state.cframe, "Ambil posisi karakter terlebih dahulu.")
        if not state.pendingMutation then
            state.pendingMutation = {name = name, cframe = {table.unpack(state.cframe)}}
            if state.selected then
                state.pendingMutation.location_id = state.selected.id
                state.pendingMutation.revision = state.selected.revision
            else state.pendingMutation.request_id = HttpService:GenerateGUID(false) end
        end
        local result = call(state.selected and "update" or "add", state.pendingMutation)
        state.pendingMutation = nil
        state.locations, state.selected, state.stale = result.locations, result.location, false
        state.cframe = {table.unpack(result.location.cframe)}
        editorTitle.Text = "EDIT LOKASI"
        editorHelp.Text = "Ubah nama, atau ambil posisi baru untuk mengganti koordinat."
        deleteButton.Visible = true
        saveButton.Size = UDim2.new(1, -102, 0, 36)
        displayCoordinates(); render()
        status(result.message)
    end)
end
local function viewport()
    local camera = Workspace.CurrentCamera
    local size = camera and camera.ViewportSize or Vector2.new(800, 600)
    local topLeft, bottomRight = GuiService:GetGuiInset()
    return Vector2.new(math.max(160, size.X - topLeft.X - bottomRight.X), math.max(120, size.Y - topLeft.Y - bottomRight.Y))
end
local function clampPosition()
    local size = viewport()
    local halfWidth = state.width * state.scale / 2
    local halfHeight = (state.minimized and 44 or state.height) * state.scale / 2
    state.center = state.center or Vector2.new(size.X / 2, size.Y / 2)
    state.center = Vector2.new(math.clamp(state.center.X, halfWidth + 6, math.max(halfWidth + 6, size.X - halfWidth - 6)),
        math.clamp(state.center.Y, halfHeight + 6, math.max(halfHeight + 6, size.Y - halfHeight - 6)))
    panel.Position = UDim2.fromOffset(state.center.X, state.center.Y)
end
layout = function()
    local size = viewport()
    state.width = math.min(620, math.max(280, size.X - 24))
    state.height = math.min(420, math.max(240, size.Y - 24))
    state.scale = math.min(1, (size.X - 16) / state.width, (size.Y - 16) / state.height)
    state.compact = state.width < 560
    scale.Scale = state.scale
    panel.Size = UDim2.fromOffset(state.width, state.minimized and 44 or state.height)
    body.Visible, footer.Visible = not state.minimized, not state.minimized
    tabs.Visible = state.compact and not state.minimized
    local top = state.compact and 90 or 54
    body.Position = UDim2.fromOffset(14, top)
    body.Size = UDim2.new(1, -28, 0, state.height - top - 48)
    if state.compact then
        left.Size = UDim2.fromScale(1, 1); left.Position = UDim2.fromOffset(0, 0)
        right.Size = UDim2.fromScale(1, 1); right.Position = UDim2.fromOffset(0, 0)
        left.Visible, right.Visible = state.activePane == "list", state.activePane == "editor"
    else
        left.Size = UDim2.new(0.46, -9, 1, 0); left.Position = UDim2.fromOffset(0, 0)
        right.Size = UDim2.new(0.54, -9, 1, 0); right.Position = UDim2.new(0.46, 9, 0, 0)
        left.Visible, right.Visible = true, true
    end
    listTab.BackgroundColor3 = state.activePane == "list" and colors.accentSoft or colors.raised
    editorTab.BackgroundColor3 = state.activePane == "editor" and colors.accentSoft or colors.raised
    minimizeButton.Text = state.minimized and "+" or "-"
    clampPosition()
end
local setupOk, setupError = pcall(function()
    screen = create("ScreenGui", {Name = "RennHSGLocations", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 100, IgnoreGuiInset = false}, player:WaitForChild("PlayerGui"))
    panel = create("Frame", {Name = "Window", Size = UDim2.fromOffset(620,420), AnchorPoint = Vector2.new(0.5,0.5), Position = UDim2.fromScale(0.5,0.5), BackgroundColor3 = colors.background, BorderSizePixel = 0}, screen)
    rounded(panel, 12); outline(panel)
    scale = create("UIScale", {Scale = 1}, panel)
    titleBar = create("Frame", {Name = "DragHandle", Active = true, Size = UDim2.new(1,-88,0,44), BackgroundTransparency = 1}, panel)
    local emblem = label("R", UDim2.fromOffset(26,26), UDim2.fromOffset(12,9), titleBar, 16, colors.accent)
    emblem.Font = Enum.Font.GothamBlack
    local title = label("RENNHSG  /  LOKASI", UDim2.new(1,-50,1,0), UDim2.fromOffset(48,0), titleBar, 13)
    title.Font = Enum.Font.GothamBold
    minimizeButton = button("-", UDim2.fromOffset(30,28), UDim2.new(1,-76,0,8), panel)
    local close = button("x", UDim2.fromOffset(30,28), UDim2.new(1,-40,0,8), panel)
    close.TextColor3 = colors.danger
    connect(close.Activated, state.cleanup)
    connect(minimizeButton.Activated, function() state.minimized = not state.minimized; layout() end)
    tabs = create("Frame", {Size = UDim2.new(1,-28,0,30), Position = UDim2.fromOffset(14,50), BackgroundTransparency = 1}, panel)
    listTab = button("Daftar", UDim2.new(0.5,-4,1,0), UDim2.fromOffset(0,0), tabs)
    editorTab = button("Editor", UDim2.new(0.5,-4,1,0), UDim2.new(0.5,4,0,0), tabs)
    connect(listTab.Activated, function() state.activePane = "list"; layout() end)
    connect(editorTab.Activated, function() state.activePane = "editor"; layout() end)
    body = create("Frame", {Name = "Content", BackgroundTransparency = 1}, panel)
    left = create("Frame", {Name = "LocationList", BackgroundTransparency = 1}, body)
    right = create("ScrollingFrame", {Name = "Editor", BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
        ScrollBarImageColor3 = colors.muted, CanvasSize = UDim2.fromOffset(0,312), ScrollingDirection = Enum.ScrollingDirection.Y}, body)
    local form = create("Frame", {Size = UDim2.new(1,-6,0,312), BackgroundTransparency = 1}, right)
    searchInput = input("Cari lokasi...", UDim2.new(1,-42,0,34), UDim2.fromOffset(0,0), left)
    refreshButton = button("R", UDim2.fromOffset(34,34), UDim2.new(1,-34,0,0), left)
    countLabel = label("LOKASI WEBSITE", UDim2.new(1,-86,0,30), UDim2.fromOffset(0,42), left, 10, colors.muted)
    newButton = button("+ Baru", UDim2.fromOffset(76,28), UDim2.new(1,-76,0,43), left)
    list = create("ScrollingFrame", {Size = UDim2.new(1,0,1,-80), Position = UDim2.fromOffset(0,80), BackgroundTransparency = 1,
        BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = colors.muted, CanvasSize = UDim2.fromOffset(0,0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y}, left)
    create("UIListLayout", {Padding = UDim.new(0,7), SortOrder = Enum.SortOrder.LayoutOrder}, list)
    editorTitle = label("TAMBAH LOKASI", UDim2.new(1,0,0,24), UDim2.fromOffset(0,0), form, 15)
    editorTitle.Font = Enum.Font.GothamBold
    editorHelp = label("Beri nama dan simpan posisi karakter ke website.", UDim2.new(1,0,0,30), UDim2.fromOffset(0,25), form, 11, colors.muted)
    editorHelp.TextWrapped = true
    label("Nama lokasi", UDim2.new(1,0,0,18), UDim2.fromOffset(0,63), form, 11, colors.muted)
    nameInput = input("Contoh: Spot mancing baru", UDim2.new(1,0,0,36), UDim2.fromOffset(0,84), form)
    label("KOORDINAT TERSIMPAN", UDim2.new(1,0,0,18), UDim2.fromOffset(0,133), form, 10, colors.muted)
    coordinateLabel = label("Posisi belum diambil", UDim2.new(1,0,0,58), UDim2.fromOffset(0,155), form, 11, colors.accent)
    coordinateLabel.BackgroundTransparency = 0; coordinateLabel.BackgroundColor3 = colors.paper
    rounded(coordinateLabel, 7); outline(coordinateLabel)
    create("UIPadding", {PaddingLeft = UDim.new(0,12)}, coordinateLabel)
    captureButton = button("Ambil posisi karakter", UDim2.new(1,0,0,34), UDim2.fromOffset(0,222), form)
    saveButton = button("Tambah ke website", UDim2.new(1,0,0,36), UDim2.fromOffset(0,266), form, true)
    deleteButton = button("Hapus", UDim2.fromOffset(92,36), UDim2.new(1,-92,0,266), form)
    deleteButton.TextColor3 = colors.danger; deleteButton.Visible = false
    controls = {saveButton, deleteButton, captureButton, refreshButton, newButton}
    footer = create("Frame", {Size = UDim2.new(1,-28,0,34), Position = UDim2.new(0,14,1,-40), BackgroundTransparency = 1}, panel)
    statusLabel = label("Menghubungkan dengan akses Teleport...", UDim2.fromScale(1,1), UDim2.fromOffset(0,0), footer, 10, colors.muted)
    statusLabel.TextWrapped = true
    render = function()
        for _, object in ipairs(list:GetChildren()) do if object:IsA("TextButton") or object:IsA("TextLabel") then object:Destroy() end end
        local query = searchInput.Text:lower()
        local visible = 0
        for _, location in ipairs(state.locations) do
            if query == "" or tostring(location.name):lower():find(query,1,true) or tostring(location.id):lower():find(query,1,true) then
                visible = visible + 1
                local item = location
                local row = button("", UDim2.new(1,-7,0,58), UDim2.fromOffset(0,0), list)
                row.LayoutOrder = visible
                local selected = state.selected and state.selected.id == item.id
                row.BackgroundColor3 = selected and colors.accentSoft or colors.paper
                local name = label(tostring(item.name), UDim2.new(1,-20,0,24), UDim2.fromOffset(10,5), row, 12, selected and colors.accent or colors.text)
                name.Font = Enum.Font.GothamBold; name.TextTruncate = Enum.TextTruncate.AtEnd
                label(string.format("X %.1f  Y %.1f  Z %.1f", item.cframe[1], item.cframe[2], item.cframe[3]), UDim2.new(1,-20,0,18), UDim2.fromOffset(10,31), row, 10, colors.muted).TextTruncate = Enum.TextTruncate.AtEnd
                row.Activated:Connect(function() selectLocation(item) end)
            end
        end
        countLabel.Text = "LOKASI WEBSITE  /  " .. tostring(#state.locations)
        listTab.Text = "Daftar (" .. tostring(#state.locations) .. ")"
        if visible == 0 then
            local empty = label("Tidak ada lokasi yang cocok.", UDim2.new(1,-8,0,48), UDim2.fromOffset(0,0), list, 11, colors.muted)
            empty.TextWrapped = true
        end
    end
    connect(searchInput:GetPropertyChangedSignal("Text"), render)
    connect(nameInput:GetPropertyChangedSignal("Text"), function() if not state.busy then state.pendingMutation = nil end end)
    connect(refreshButton.Activated, function() perform(function() refresh(false) end) end)
    connect(newButton.Activated, newLocation)
    connect(captureButton.Activated, function()
        if state.busy or not state.authorized then return end
        local ok, values = pcall(takePosition)
        if ok then state.cframe, state.pendingMutation = values, nil; displayCoordinates(); updateControls(); status("Posisi diambil. Tekan Simpan untuk memperbarui website.")
        else status(values, true) end
    end)
    connect(saveButton.Activated, saveLocation)
    local overlay = create("Frame", {Name = "DeleteConfirmation", Size = UDim2.fromScale(1,1), BackgroundColor3 = colors.background,
        BackgroundTransparency = 0.04, BorderSizePixel = 0, Visible = false, Active = true, ZIndex = 20}, panel)
    rounded(overlay, 12)
    local confirmTitle = label("HAPUS LOKASI?", UDim2.new(1,-40,0,30), UDim2.new(0,20,0.5,-90), overlay, 16, colors.danger)
    confirmTitle.Font = Enum.Font.GothamBold
    local confirmText = label("", UDim2.new(1,-40,0,70), UDim2.new(0,20,0.5,-52), overlay, 12)
    confirmText.TextWrapped = true
    local cancel = button("Batal", UDim2.new(0.5,-24,0,38), UDim2.new(0,20,0.5,34), overlay)
    local confirm = button("Hapus dari website", UDim2.new(0.5,-24,0,38), UDim2.new(0.5,4,0.5,34), overlay)
    confirm.TextColor3 = colors.danger
    connect(cancel.Activated, function() overlay.Visible = false; state.confirming = false end)
    connect(deleteButton.Activated, function()
        if state.busy or not state.selected or state.stale or not state.authorized then return end
        state.confirming = true
        confirmText.Text = '"' .. tostring(state.selected.name) .. '" akan dihapus dari daftar lokasi website. Lanjutkan?'
        overlay.Visible = true
    end)
    connect(confirm.Activated, function()
        if state.busy then return end
        overlay.Visible = false; state.confirming = false
        local selected = state.selected
        if not selected then return end
        perform(function()
            local result = call("delete", {location_id = selected.id, revision = selected.revision})
            state.locations = result.locations
            state.selected, state.cframe, state.pendingMutation, state.stale = nil, nil, nil, false
            nameInput.Text = ""; editorTitle.Text = "TAMBAH LOKASI"
            editorHelp.Text = "Beri nama dan simpan posisi karakter ke website."
            deleteButton.Visible = false; saveButton.Size = UDim2.new(1,0,0,36)
            state.activePane = "list"
            displayCoordinates(); render(); layout(); status(result.message)
        end)
    end)
    local dragInput, dragStart, dragCenter
    connect(titleBar.InputBegan, function(event)
        if event.UserInputType == Enum.UserInputType.MouseButton1 or event.UserInputType == Enum.UserInputType.Touch then
            if state.confirming then return end
            dragInput, dragStart, dragCenter = event, event.Position, state.center
        end
    end)
    connect(UserInputService.InputChanged, function(event)
        if dragInput and (event == dragInput or (dragInput.UserInputType == Enum.UserInputType.MouseButton1 and event.UserInputType == Enum.UserInputType.MouseMovement)) then
            local delta = event.Position - dragStart
            state.center = Vector2.new(dragCenter.X + delta.X, dragCenter.Y + delta.Y)
            clampPosition()
        end
    end)
    connect(UserInputService.InputEnded, function(event) if event == dragInput then dragInput = nil end end)
    local cameraConnection
    local function trackCamera()
        if cameraConnection then cameraConnection:Disconnect() end
        if Workspace.CurrentCamera then cameraConnection = connect(Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"), layout) end
        layout()
    end
    connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), trackCamera)
    trackCamera(); render(); updateControls()
end)
if not setupOk then state.cleanup(); error(setupError) end
perform(function() refresh(false) end)
task.spawn(function()
    while not state.destroyed and state.authorized do
        task.wait(20)
        if not state.destroyed and not state.busy and not state.confirming then perform(function() refresh(true) end) end
    end
end)
