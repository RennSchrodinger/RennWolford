-- RennHSG Auto Point. Publish this file as autopoint.lua in RennSchrodinger/RennWolford main.
local env = (getgenv and getgenv()) or _G
local key = tostring(env.RENNHSG_AUTOPOINT_CODE or "")
env.RENNHSG_AUTOPOINT_CODE = nil
assert(key ~= "", "Jalankan loader Auto Point dari panel web.")
local Players = game:GetService("Players")
local Http = game:GetService("HttpService")
local Chat = game:GetService("TextChatService")
local UIS = game:GetService("UserInputService")
local player = Players.LocalPlayer
local requestFn = request or http_request or (syn and syn.request) or (http and http.request) or env.request or env.http_request
assert(type(requestFn) == "function", "Executor memerlukan request/http_request.")
local ENDPOINT = "https://auxpoint.rennhsg.my.id/lua.php"
local function post(payload)
    payload.key = key
    local response = requestFn({Url=ENDPOINT,Method="POST",Headers={["Content-Type"]="application/json"},Body=Http:JSONEncode(payload),Timeout=10})
    assert(type(response)=="table", "Backend tidak memberikan respons.")
    local ok, result = pcall(Http.JSONDecode, Http, response.Body or response.body or "")
    assert(ok and type(result)=="table", "Respons backend tidak valid.")
    assert(result.ok, tostring(result.error or "Permintaan ditolak."))
    return result
end
post({action="verify"})
if type(env.RENN_AUTOPOINT_CLOSE)=="function" then env.RENN_AUTOPOINT_CLOSE() end
local alive, busy, connected = true, false, false
local token, sessionId, session, clockEpoch, clockBase = "", "", nil, 0, os.clock()
local queue, connections, recentIds = {}, {}, {}
local cacheFile = nil
local function fileFn(name)
    local fn=env[name] or rawget(_G,name)
    return type(fn)=="function" and fn or nil
end
local function saveQueue()
    if not cacheFile then return end
    env.RENN_AUTOPOINT_QUEUE = env.RENN_AUTOPOINT_QUEUE or {}
    env.RENN_AUTOPOINT_QUEUE[cacheFile] = queue
    local write, make = fileFn("writefile"), fileFn("makefolder")
    if make then pcall(make,"RennHSG") end
    if write then
        local ok,err=pcall(write,cacheFile,Http:JSONEncode({events=queue}))
        if not ok then warn("[Auto Point] Cache file gagal: "..tostring(err)) end
    end
end
local function loadQueue()
    queue={}
    if env.RENN_AUTOPOINT_QUEUE and type(env.RENN_AUTOPOINT_QUEUE[cacheFile])=="table" then
        queue=env.RENN_AUTOPOINT_QUEUE[cacheFile]; return
    end
    local read=fileFn("readfile")
    if read then
        local ok,raw=pcall(read,cacheFile)
        if ok then
            local parsed,data=pcall(Http.JSONDecode,Http,raw)
            if parsed and type(data)=="table" and type(data.events)=="table" then queue=data.events end
        end
    end
end
local gui=Instance.new("ScreenGui")
gui.Name="RennAutoPoint";gui.ResetOnSpawn=false;gui.ZIndexBehavior=Enum.ZIndexBehavior.Sibling;gui.Parent=player:WaitForChild("PlayerGui")
local panel=Instance.new("Frame");panel.Size=UDim2.fromOffset(410,420);panel.Position=UDim2.new(.5,-205,.5,-210);panel.BackgroundColor3=Color3.fromRGB(22,26,28);panel.Parent=gui
local corner=Instance.new("UICorner");corner.CornerRadius=UDim.new(0,10);corner.Parent=panel
local stroke=Instance.new("UIStroke");stroke.Color=Color3.fromRGB(62,73,61);stroke.Parent=panel
local function label(text,y,height)
    local l=Instance.new("TextLabel");l.Position=UDim2.fromOffset(20,y);l.Size=UDim2.new(1,-40,0,height or 24);l.BackgroundTransparency=1;l.Text=text;l.Font=Enum.Font.Gotham;l.TextSize=13;l.TextColor3=Color3.fromRGB(230,237,228);l.TextXAlignment=Enum.TextXAlignment.Left;l.TextWrapped=true;l.Parent=panel;return l
end
local title=label("RENNHSG / AUTO POINT",16,30);title.TextColor3=Color3.fromRGB(195,239,115);title.Font=Enum.Font.GothamBold
local code=Instance.new("TextBox");code.Position=UDim2.fromOffset(20,60);code.Size=UDim2.new(1,-40,0,38);code.BackgroundColor3=Color3.fromRGB(34,40,42);code.TextColor3=Color3.fromRGB(238,241,234);code.PlaceholderText="KODE SESSION · XXX-XXX";code.Text="";code.ClearTextOnFocus=false;code.TextSize=17;code.Font=Enum.Font.GothamBold;code.Parent=panel
local info=label("Masukkan kode session dari panel admin.",154,52)
local timerLabel=label("SISA WAKTU  —",213,30);timerLabel.Font=Enum.Font.GothamBold;timerLabel.TextSize=20
local activity=label("Menunggu pertandingan.",345,50)
local status=label("Key tervalidasi · belum terhubung",395,18);status.TextSize=10
local function button(text,x,y,width,fn)
    local b=Instance.new("TextButton");b.Text=text;b.Position=UDim2.fromOffset(x,y);b.Size=UDim2.fromOffset(width,36);b.BackgroundColor3=Color3.fromRGB(45,57,39);b.TextColor3=Color3.fromRGB(195,239,115);b.Font=Enum.Font.GothamBold;b.TextSize=12;b.Parent=panel
    table.insert(connections,b.MouseButton1Click:Connect(fn));return b
end
local function serverNow() return clockEpoch+(os.clock()-clockBase) end
local function timeText(seconds)
    seconds=math.max(0,math.ceil(seconds));return string.format("%02d:%02d:%02d",math.floor(seconds/3600),math.floor(seconds/60)%60,seconds%60)
end
local function apply(result)
    session=result.session
    if not session then return end
    clockEpoch=session.server_time;clockBase=os.clock()
    info.Text=session.name.."\nSTATUS: "..session.status.." · "..tostring(#session.participants).." peserta"
    local acknowledged={}
    for _,ack in ipairs(result.acks or {}) do
        acknowledged[ack.id]=true
        if ack.result=="accepted" then activity.Text="Tangkapan diterima · +"..tostring(ack.delta).." poin"
        elseif ack.result~="duplicate" then activity.Text="Tangkapan perlu diperiksa pada log website." end
    end
    if next(acknowledged) then
        local remaining={};for _,event in ipairs(queue) do if not acknowledged[event.id] then table.insert(remaining,event) end end
        queue=remaining;saveQueue()
    end
    status.Text="Terhubung · antrean "..tostring(#queue).." · "..session.status
    if session.status=="ENDED" then
        connected=false;status.Text="ENDED · hasil akhir tersedia di website. Antrean tersisa: "..tostring(#queue)
    end
end
local function sync(action)
    if busy or not connected then return end
    busy=true
    local ok,err=pcall(function()
        local roster={};for _,p in ipairs(Players:GetPlayers()) do table.insert(roster,{display_name=p.DisplayName,username=p.Name}) end
        local events={};for i=1,math.min(20,#queue) do table.insert(events,queue[i]);if #Http:JSONEncode(events)>24000 then table.remove(events);break end end
        local result=post({action=action or "sync",session_id=sessionId,token=token,roster=roster,events=events})
        apply(result)
    end)
    if not ok then status.Text="Koneksi / aksi gagal: "..tostring(err);if tostring(err):find("Koneksi dicabut",1,true) then connected=false end;saveQueue() end
    busy=false
end
button("CONNECT",20,109,370,function()
    if busy then return end
    if connected then status.Text="Sudah terhubung. Gunakan START / RESUME.";return end
    busy=true
    local ok,err=pcall(function()
        local result=post({action="connect",code=code.Text:upper():gsub("%s+",""),user_id=tostring(player.UserId),username=player.Name,display_name=player.DisplayName,job_id=game.JobId})
        token=result.token;sessionId=result.session_id;cacheFile="RennHSG/autopoint-"..sessionId.."-"..tostring(player.UserId)..".json";loadQueue();connected=true;apply(result)
    end)
    if not ok then status.Text=tostring(err) end
    busy=false
end)
button("START / RESUME",20,262,370,function()sync("start")end)
button("PAUSE",20,305,180,function()sync("pause")end)
local endArmed=false
button("END",210,305,180,function()
    if not endArmed then endArmed=true;status.Text="Tekan END sekali lagi dalam 4 detik untuk mengakhiri.";task.delay(4,function()endArmed=false end);return end
    endArmed=false;sync("end")
end)
local function strip(text)
    text=tostring(text or ""):gsub("<[^>]->", "")
    return (text:gsub("&lt;","<"):gsub("&gt;",">"):gsub("&amp;","&"):gsub("&quot;",'"'):gsub("^%s+",""):gsub("%s+$",""))
end
local function normalize(text)return strip(text):lower():gsub("%s+"," ")end
local function parse(text)
    local plain=strip(text)
    if plain:lower():find("global",1,true) then return end
    plain=plain:gsub("^%[[Ss][Ee][Rr][Vv][Ee][Rr]%]:%s*","")
    local name,fish=plain:match("^(.-)%s+[Oo][Bb][Tt][Aa][Ii][Nn][Ee][Dd]%s+[Aa][Nn]?%s+(.-)%s+[Ww][Ii][Tt][Hh]%s+[Aa]%s+.-%s+[Cc][Hh][Aa][Nn][Cc][Ee]!")
    if not name then return end
    fish=fish:gsub("%s*%([^)]*%)%s*$","")
    local spans={}
    for attributes, span in text:gmatch("<[Ff][Oo][Nn][Tt]%s+([^>]*)>(.-)</[Ff][Oo][Nn][Tt]>") do
        local value=strip(span):gsub("%s*%([^)]*%)%s*$","")
        if attributes:lower():find("color",1,true) and value~="" and normalize(value)~=normalize(name) and normalize(value)~="[server]:" and normalize(value)~="server" then table.insert(spans,value) end
    end
    local mutations={};local known=false
    if #spans>0 then
        fish=spans[#spans];known=true
        for i=1,#spans-1 do
            if normalize(spans[i])~="none" then table.insert(mutations,spans[i]) end
        end
    end
    -- Match canonical rule names even when the game puts mutation + fish in one
    -- span, or sends plain system text without RichText colors.
    local rawFish=plain:match("^.-%s+[Oo][Bb][Tt][Aa][Ii][Nn][Ee][Dd]%s+[Aa][Nn]?%s+(.-)%s+[Ww][Ii][Tt][Hh]%s+[Aa]%s+.-%s+[Cc][Hh][Aa][Nn][Cc][Ee]!")
    rawFish=strip((rawFish or fish):gsub("%s*%([^)]*%)%s*$",""))
    local best=nil
    for _,rule in ipairs(session and session.rules or {}) do
        local raw,canonical=normalize(rawFish),normalize(rule.fish)
        if raw==canonical or (#raw>#canonical and raw:sub(-#canonical)==canonical and raw:sub(-#canonical-1,-#canonical-1)==" ") then
            if not best or #canonical>#normalize(best.fish) then best=rule end
        end
    end
    if best then
        local raw,canonical=normalize(rawFish),normalize(best.fish)
        local prefix=strip(raw:sub(1,#raw-#canonical))
        fish=best.fish;known=true;mutations={}
        if prefix~="" and prefix~="none" then table.insert(mutations,prefix) end
    end
    return strip(name),strip(fish),mutations,known
end
local function receive(message)
    if not alive or not connected or not session or session.status~="RUNNING" then return end
    -- Only system announcements count; ordinary player chat cannot award points.
    if message.TextSource~=nil then return end
    local channel="";pcall(function()channel=message.TextChannel.Name end)
    if channel:lower():find("global",1,true) then return end
    local text=message.Text or "";local name,fish,mutations,known=parse(text)
    if not name then return end
    local eligible=false;for _,rule in ipairs(session.rules or {}) do if normalize(rule.fish)==normalize(fish) then eligible=true;break end end
    if not eligible then return end
    local id=tostring(message.MessageId or "")
    if id=="" then id=Http:GenerateGUID(false) end
    id=id:gsub("[^%w_-]", "_")
    if #id<12 then id=Http:GenerateGUID(false) end
    if recentIds[id] then return end
    recentIds[id]=true
    if #queue>=5000 then status.Text="Antrean penuh: PAUSE dan periksa koneksi backend.";warn("[Auto Point] Antrean penuh; tangkapan: "..text);return end
    table.insert(queue,{id=id,display_name=name,fish=fish,mutations=mutations,mutation_known=known,caught_at=serverNow(),run_id=session.run_id,raw=text})
    saveQueue();activity.Text=name.." · "..fish.." · menunggu konfirmasi"
end
-- Use the signal instead of overwriting OnIncomingMessage used by other scripts.
table.insert(connections,Chat.MessageReceived:Connect(receive))
local dragging,dragStart,startPos=false,nil,nil
table.insert(connections,title.InputBegan:Connect(function(input)
    if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then dragging=true;dragStart=input.Position;startPos=panel.Position end
end))
table.insert(connections,UIS.InputEnded:Connect(function(input)if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then dragging=false end end))
table.insert(connections,UIS.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType==Enum.UserInputType.MouseMovement or input.UserInputType==Enum.UserInputType.Touch) then local d=input.Position-dragStart;panel.Position=UDim2.new(startPos.X.Scale,startPos.X.Offset+d.X,startPos.Y.Scale,startPos.Y.Offset+d.Y) end
end))
local function close()
    alive=false;saveQueue();for _,c in ipairs(connections)do c:Disconnect()end;gui:Destroy();env.RENN_AUTOPOINT_CLOSE=nil
end
env.RENN_AUTOPOINT_CLOSE=close
button("×",365,18,25,close)
task.spawn(function()
    while alive do
        if connected then
            sync("sync")
            -- A heartbeat that discovers a disconnect pause completes acknowledgement
            -- before resuming. Explicit manual pauses never auto-resume.
            if session and session.status=="PAUSED" and session.pause_reason=="disconnect" and #queue==0 then sync("start") end
        end
        task.wait(3)
    end
end)
task.spawn(function()
    while alive do
        if session then
            local left=session.remaining-(session.status=="RUNNING" and (os.clock()-clockBase) or 0)
            timerLabel.Text="SISA WAKTU  "..timeText(left)
        end
        task.wait(.25)
    end
end)
if not fileFn("writefile") then status.Text="Cache memori aktif; executor tidak mendukung penyimpanan antrean ke file." end




