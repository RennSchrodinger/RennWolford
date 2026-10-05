-- Renn Fishing Insight v1. Read-only live dashboard; no remote calls or hooks.
-- Configuration defaults come from pittytest.JSON; live configuration takes precedence.
local Core=(function()
    local M={defaults={CastsToMax=12000,MaxPityAdditive=30,AFKPityRate=0.75,PityRate=1,
        GoodDropTier=6,ResetTierThreshold=7,Crumbs={DryStreak={Threshold=3000,ChancePerCast=0.2}}}}
    function M.finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
    function M.number(n,places)
        if not M.finite(n) then return "Belum terbaca" end
        local text=string.format("%."..(places or 2).."f",n)
        local whole,frac=text:match("^(%-?%d+)%.(%d+)$")
        whole=whole or text
        frac=frac and frac:gsub("0+$","") or ""
        local sign=whole:sub(1,1)=="-" and "-" or ""
        whole=whole:gsub("^-",""):reverse():gsub("(%d%d%d)","%1."):reverse():gsub("^%.","")
        return sign..whole..(frac~="" and ","..frac or "")
    end
    function M.duration(seconds)
        if not M.finite(seconds) or seconds<0 then return "Belum ada estimasi waktu" end
        if seconds<60 then return math.ceil(seconds).." detik" end
        local minutes=math.ceil(seconds/60)
        if minutes<60 then return minutes.." menit" end
        if minutes<1440 then return math.floor(minutes/60).." jam "..(minutes%60).." menit" end
        return math.floor(minutes/1440).." hari "..math.floor(minutes%1440/60).." jam"
    end
    function M.root(data)
        if type(data)~="table" then return end
        if type(data.Statistics)=="table" or type(data.LuckRevamp)=="table" then return data end
        if type(data.Profile)=="table" then return M.root(data.Profile) end
        if type(data.Data)=="table" then return M.root(data.Data) end
    end
    function M.owns(profile,userId)
        if type(profile)~="table" or profile.Destroyed or type(profile.Data)~="table" then return false end
        local root=M.root(profile.Data)
        if not root then return false end
        for _,data in ipairs({profile.Data,root}) do
            if data.Participants or data.Offers or data.Players then return false end
            for _,key in ipairs({"UserId","OwnerUserId","PlayerUserId"}) do
                if data[key]~=nil and tonumber(data[key])~=userId then return false end
            end
        end
        local owner=profile.ReplicateTo
        if owner=="All" then return false end
        if typeof(owner)=="Instance" and owner:IsA("Player") and owner.UserId~=userId then return false end
        if type(owner)=="table" then
            for _,item in pairs(owner) do
                if typeof(item)=="Instance" and item:IsA("Player") and item.UserId~=userId then return false end
            end
        end
        return ({Data=true,PlayerData=true,Profile=true})[profile._channel] or false
    end
    function M.tier(value)
        if value==6 or value==7 or value==8 then return value end
        if type(value)=="string" then
            local s=value:lower()
            if s=="mythic" or s=="mythical" then return 6 end
            if s=="secret" then return 7 end
            if s=="forgotten" then return 8 end
        end
    end
    function M.inventory(root)
        local stock,complete={},true
        local inventory=root and root.Inventory
        if type(inventory)~="table" then return stock,false end
        local count=0
        for collection,items in pairs(inventory) do
            if type(items)=="table" then
                for _,record in pairs(items) do
                    count+=1; if count>50000 then return stock,false end
                    if type(record)=="table" and type(record.UUID)=="string" then
                        local qty=record.Quantity or 1
                        if stock[record.UUID] or not M.finite(qty) or qty<0 or qty%1~=0 then complete=false
                        else stock[record.UUID]={record=record,collection=collection,quantity=qty,id=record.Id} end
                    end
                end
            end
        end
        return stock,complete
    end
    function M.definitionName(definition,fallback)
        local data=type(definition)=="table" and (definition.Data or definition) or {}
        return type(data.Name)=="string" and data.Name or fallback
    end
    function M.fish(entry,resolve)
        if type(entry)~="table" or not entry.id then return end
        local definition=resolve("Fish",entry.id)
        if type(definition)~="table" then return end
        local data=definition.Data or definition
        if data.Type~="Fish" and entry.collection~="Fish" and entry.collection~="Fishes" then return end
        return {id=entry.id,name=M.definitionName(definition,"Ikan #"..tostring(entry.id)),
            tier=M.tier(data.Tier or data.Rarity),rawTier=data.Tier or data.Rarity}
    end
    function M.equipment(root,stock,resolve,enchant)
        local out={}; local equipped=root.EquippedItems or {}
        local function uuidRecord(uuid)
            local entry=type(uuid)=="string" and stock[uuid]
            return entry and entry.record,entry and entry.collection
        end
        local function row(label,collection,record,id)
            id=record and record.Id or id
            if id==nil or id==0 then out[#out+1]={label=label,value="Tidak dipakai"}; return end
            local definition=resolve(collection,id)
            local name=M.definitionName(definition,label.." #"..tostring(id))
            if record and type(record.Metadata)=="table" then
                local names={}
                for _,key in ipairs({"EnchantId","EnchantId2"}) do
                    local n=record.Metadata[key]
                    if n and n~=0 then names[#names+1]=enchant(n) or ("Enchant #"..tostring(n)) end
                end
                if #names>0 then name=name.."\n"..table.concat(names," + ") end
            end
            out[#out+1]={label=label,value=name}
        end
        local rod=uuidRecord(equipped[1] or root.EquippedId)
        row("Joran","Fishing Rods",rod)
        if not rod and type(equipped[1] or root.EquippedId)=="string" and (equipped[1] or root.EquippedId)~="" then out[#out].value="Joran dipakai; nama belum terbaca" end
        local bait=uuidRecord(root.EquippedBaitUUID)
        row("Umpan","Baits",bait,root.EquippedBaitId)
        local pet=uuidRecord(root.EquippedPetUUID)
        row("Pet utama","Pets",pet)
        if not pet and type(root.EquippedPetUUID)=="string" and root.EquippedPetUUID~="" then out[#out].value="Pet dipakai; nama belum terbaca" end
        local support=uuidRecord(root.EquippedSupportPetUUID)
        row("Pet pendukung","Pets",support)
        if not support and type(root.EquippedSupportPetUUID)=="string" and root.EquippedSupportPetUUID~="" then out[#out].value="Pet dipakai; nama belum terbaca" end
        row("Charm","Charms",nil,root.EquippedCharmId)
        row("Lentera","Lanterns",nil,root.EquippedLanternId)
        for _,pair in ipairs({{"Equipment 1","EquippedEquipmentId"},{"Equipment 2","EquippedEquipmentId2"}}) do
            row(pair[1],"Equipment",nil,root[pair[2]])
        end
        local ability=root.Abilities or {}; local abilityName
        for _,item in pairs(ability.Inventory or {}) do
            if item.UUID==ability.Equipped then abilityName=item.Name; break end
        end
        local active=ability.Equipped and ability.Active==ability.Equipped and (ability.ActiveRollsRemaining or 0)>0
        out[#out+1]={label="Ability",value=abilityName and (abilityName..(active and (" · aktif, sisa "..M.number(ability.ActiveRollsRemaining,0).." tangkapan") or " · belum aktif")) or "Tidak dipakai"}
        return out
    end
    function M.newHistory()
        return {sessionCaught=0,classified=0,rare={},lastRare={},intervals={},rates={},pace={},unknown=0,locationGeneration=0}
    end
    function M.observe(history,sample,resolve)
        local prior=history.previous
        history.previous=sample
        if not prior then return {baseline=true} end
        if prior.location~=sample.location then history.locationGeneration+=1 end
        local remembered=table.clone(history.lastRare)
        local analytics,oldAnalytics=sample.analytics or {},prior.analytics or {}
        for tier,key in pairs({[7]="LastSecretTimestamp",[8]="LastForgottenTimestamp"}) do
            if M.finite(analytics[key]) and M.finite(oldAnalytics[key]) and analytics[key]>oldAnalytics[key] then history.lastRare[tier]=nil end
        end
        local count=sample.caught-prior.caught
        if count<0 or count>1000 or sample.source~=prior.source then
            history.rates={}; history.pace={}; history.previousCatchAt=nil; history.lastCatchAt=nil
            history.locationGeneration+=1; return {gap=true}
        end
        if sample.location==prior.location and M.finite(sample.pity) and M.finite(prior.pity) and sample.pity<prior.pity then history.rates={} end
        if count==0 then return {} end
        history.sessionCaught+=count; history.lastCatchAt=sample.now
        local elapsed=sample.now-prior.now
        -- Use time since the preceding counter change, not the polling interval.
        if history.previousCatchAt then
            elapsed=sample.now-history.previousCatchAt
            if elapsed>0 and elapsed<=120 then
                history.pace[#history.pace+1]={seconds=elapsed,count=count}
                if #history.pace>20 then table.remove(history.pace,1) end
            end
        end
        history.previousCatchAt=sample.now
        if sample.location==prior.location and sample.location then
            local after,before=sample.pity,prior.pity
            if M.finite(after) and M.finite(before) and after>=before and after>before then
                history.rates[#history.rates+1]={points=after-before,count=count,location=sample.location}
                if #history.rates>20 then table.remove(history.rates,1) end
            elseif M.finite(after) and M.finite(before) and after<before then history.rates={} end
        end
        if not sample.stockComplete or not prior.stockComplete or sample.trading then
            history.unknown+=count; return {count=count,unmapped=true}
        end
        local arrivals,total={},0
        for uuid,entry in pairs(sample.stock) do
            local old=prior.stock[uuid]
            local added=entry.quantity-(old and old.quantity or 0)
            if added>0 then
                local fish=M.fish(entry,resolve)
                if fish then arrivals[#arrivals+1]={fish=fish,count=added}; total+=added end
            end
        end
        -- A mismatch (sale, trade, reward, multi-step replication) cannot identify a catch.
        if total~=count then history.unknown+=count; return {count=count,unmapped=true} end
        -- A rare inventory arrival additionally needs the account's own rare/drop
        -- counters to corroborate it. A trade can finish before IsTrading is polled.
        for _,arrival in ipairs(arrivals) do
            local tier=arrival.fish.tier
            local confirmed=true
            if tier==6 then
                confirmed=M.finite(sample.dryStreak) and M.finite(prior.dryStreak) and sample.dryStreak<prior.dryStreak
            elseif tier==7 or tier==8 then
                local timeKey=tier==7 and "LastSecretTimestamp" or "LastForgottenTimestamp"
                local sinceKey=tier==7 and "FishSinceLastSecret" or "FishSinceLastForgotten"
                confirmed=(M.finite(analytics[timeKey]) and M.finite(oldAnalytics[timeKey]) and analytics[timeKey]>oldAnalytics[timeKey])
                    or (M.finite(analytics[sinceKey]) and M.finite(oldAnalytics[sinceKey]) and analytics[sinceKey]<oldAnalytics[sinceKey]+count)
            end
            if not confirmed then history.unknown+=count; return {count=count,unmapped=true} end
        end
        history.classified+=count
        local grouped,handled={},{}
        for _,arrival in ipairs(arrivals) do
            local tier=arrival.fish.tier
            if tier then
                grouped[tier]=grouped[tier] or {names={},count=0}
                local group=grouped[tier]; group.count+=arrival.count; group.names[#group.names+1]=arrival.fish.name
            end
        end
        for _,arrival in ipairs(arrivals) do
            local fish=arrival.fish
            if fish.tier and not handled[fish.tier] then
                local tier=fish.tier
                handled[tier]=true
                local group=grouped[tier]; table.sort(group.names)
                local name=#group.names>1 and (group.count.." hasil satu batch: "..table.concat(group.names,", ")) or fish.name
                local record={tier=tier,name=name,at=sample.now,timestamp=sample.timestamp,
                    caught=sample.caught,location=sample.location,count=group.count,generation=history.locationGeneration}
                local last=history.lastRare[tier] or remembered[tier]
                if last and sample.caught>last.caught and last.location==sample.location and last.generation==history.locationGeneration then
                    history.intervals[tier]=history.intervals[tier] or {}
                    local gaps=history.intervals[tier]; gaps[#gaps+1]={gap=sample.caught-last.caught,location=sample.location}
                    if #gaps>20 then table.remove(gaps,1) end
                end
                history.lastRare[tier]=record
                history.rare[#history.rare+1]=record
                if #history.rare>50 then table.remove(history.rare,1) end
            end
        end
        return {count=count}
    end
    function M.rate(history,location)
        local points,count=0,0
        for _,entry in ipairs(history.rates) do
            if entry.location==location then points+=entry.points; count+=entry.count end
        end
        return count>0 and points/count or nil,count
    end
    function M.pace(history,now)
        if not history.lastCatchAt or now-history.lastCatchAt>30 then return end
        local seconds,count=0,0
        for _,entry in ipairs(history.pace) do seconds+=entry.seconds; count+=entry.count end
        return count>=2 and seconds/count or nil
    end
    function M.estimate(value,target,rate,secondsPerCatch)
        if not M.finite(value) or not M.finite(target) or target<=0 then return {status="unavailable"} end
        if value>=target then return {status="reached",casts=0,progress=1} end
        local result={status="measuring",progress=math.clamp(value/target,0,1)}
        if M.finite(rate) and rate>0 then
            result.status="ready"; result.casts=math.ceil((target-value)/rate)
            if M.finite(secondsPerCatch) and secondsPerCatch>0 then result.seconds=result.casts*secondsPerCatch end
        end
        return result
    end
    function M.rareSummary(history,tier,currentCaught,analytics,location)
        local last=history.lastRare[tier]
        local since=last and math.max(0,currentCaught-last.caught)
        local value=tier==7 and analytics.FishSinceLastSecret or tier==8 and analytics.FishSinceLastForgotten
        if M.finite(value) and value>=0 then since=value end
        local count,sum=0,0
        for _,interval in ipairs(history.intervals[tier] or {}) do
            if location and interval.location==location then count+=1; sum+=interval.gap end
        end
        return {last=last,since=since,averageGap=count>=2 and sum/count or nil,intervalCount=count}
    end
    return M
end)()
if not game then return Core end

local env=(type(getgenv)=="function" and getgenv()) or _G
local Players=game:GetService("Players")
local RS=game:GetService("ReplicatedStorage")
local UIS=game:GetService("UserInputService")
local player=Players.LocalPlayer
if not player then warn("Renn Fishing Insight: tunggu karakter masuk ke game."); return end
local playerGui=player:WaitForChild("PlayerGui",5)
if not playerGui then warn("Renn Fishing Insight: tampilan game belum siap."); return end
local old=env.RENN_LUCK_DASHBOARD
if type(old)=="table" and type(old.Close)=="function" then pcall(old.Close) end
local state={alive=true,connections={},tasks={},clients={},history=Core.newHistory(),
    config=Core.defaults,modules={},definitionCache={},tab="Ringkasan",status="Menghubungkan data game…",userId=player.UserId}
env.RENN_LUCK_DASHBOARD=state
local render
local function spawn(fn)
    local thread
    thread=task.defer(function()
        local ok,err=pcall(fn); if not ok then state.lastError=tostring(err) end
        state.tasks[thread]=nil
    end)
    state.tasks[thread]=true; return thread
end
local function connect(signal,fn)
    local c=signal:Connect(fn); state.connections[#state.connections+1]=c; return c
end
function state.Close()
    if not state.alive then return end
    state.alive=false
    for _,c in ipairs(state.connections) do pcall(function() c:Disconnect() end) end
    for thread in pairs(state.tasks) do if thread~=coroutine.running() then pcall(task.cancel,thread) end end
    state.tasks={}
    if state.gui then state.gui:Destroy() end
end
local function boundedCall(fn,timeout)
    local done,ok,value=false,false,nil
    local worker=spawn(function() ok,value=pcall(fn); done=true end)
    local deadline=os.clock()+(timeout or 3)
    while state.alive and not done and os.clock()<deadline do task.wait(0.05) end
    if not done then pcall(task.cancel,worker); state.tasks[worker]=nil; return false,"timeout" end
    return ok,value
end
local function lookup(client,channel)
    if type(client)~="table" or type(client.GetReplion)~="function" then return end
    local ok,value=pcall(client.GetReplion,client,channel)
    if ok and type(value)=="table" and not value.Destroyed then return value end
    ok,value=pcall(client.GetReplion,channel)
    if ok and type(value)=="table" and not value.Destroyed then return value end
end
local function addClient(client)
    if type(client)=="table" and type(client.GetReplion)=="function" and not table.find(state.clients,client) then
        state.clients[#state.clients+1]=client
    end
end
local function trackers()
    for _,key in ipairs({"RENN_STATS","RENN_INVENTORY","RENN_FISHING_ACTIVITY","RENN_LUCK_PITY_RECORDER"}) do
        local tracker=env[key]
        if type(tracker)=="table" and tracker.alive and (not tracker.playerGui or tracker.playerGui==playerGui) then
            if Core.owns(tracker.replion,player.UserId) then state.profile=tracker.replion end
            addClient(tracker.client)
            for _,item in ipairs(tracker.clients or {}) do addClient(item.client or item) end
            if type(tracker.catalog)=="table" then state.catalog=tracker.catalog end
            for _,profile in pairs(tracker.profiles or {}) do
                if Core.owns(profile,player.UserId) then state.profile=profile end
            end
        end
    end
end
local function findProfile()
    trackers()
    if Core.owns(state.profile,player.UserId) then return state.profile end
    for _,client in ipairs(state.clients) do
        for _,channel in ipairs({"Data","PlayerData","Profile"}) do
            local profile=lookup(client,channel)
            if Core.owns(profile,player.UserId) then state.profile=profile; return profile end
        end
        for _,key in ipairs({"Cache","Replions","_replions","_cache"}) do
            local values=client[key]
            if type(values)=="table" then
                for _,profile in pairs(values) do
                    if Core.owns(profile,player.UserId) then state.profile=profile; return profile end
                end
            end
        end
    end
end
local function shared(channel)
    for _,client in ipairs(state.clients) do
        local replion=lookup(client,channel)
        if replion and type(replion.Data)=="table" then return replion.Data end
    end
end
local function resolve(collection,id)
    if id==nil then return end
    local key=collection..":"..tostring(id)
    if state.definitionCache[key] then return state.definitionCache[key] end
    local utility=state.modules.ItemUtility
    if utility and type(utility.GetItemDataFromItemType)=="function" then
        local ok,definition=pcall(utility.GetItemDataFromItemType,collection,id)
        if ok and type(definition)=="table" then state.definitionCache[key]=definition; return definition end
    end
    local catalog=state.catalog
    local registry=catalog and ((catalog.byCollection and catalog.byCollection[collection])
        or (catalog.byCategory and catalog.byCategory[collection]))
    local entry=registry and (registry[tostring(id)] or registry[id])
    if entry then
        return {Data={Name=entry.name,Tier=entry.tier,Type=entry.category=="Fish" and "Fish" or collection}}
    end
end
local function enchant(id)
    local utility=state.modules.ItemUtility
    if utility and type(utility.GetEnchantData)=="function" then
        local ok,data,name=pcall(utility.GetEnchantData,utility,id)
        if ok then return type(name)=="string" and name or Core.definitionName(data,nil) end
    end
end
local function location(root)
    -- LocationName is the current area consumed by PlayerStatsUtility.
    local value=player:GetAttribute("LocationName")
    if type(value)=="string" and value~="" then return value,"current" end
    -- A saved location is displayed explicitly as historical; never used for current estimates.
    value=root.LastCharacterLocationName
    if type(value)=="string" and value~="" then return value,"saved" end
    return nil,"missing"
end
local function poll()
    local profile=findProfile()
    if not profile then
        state.status="Data akun belum tersedia. Memancing boleh diteruskan."
        state.snapshot=nil; state.history.previous=nil; state.history.rates={}; state.history.pace={}
        state.history.previousCatchAt=nil; state.history.lastCatchAt=nil; state.dryRate=nil
        return
    end
    local root=Core.root(profile.Data); local stats=root.Statistics or {}
    if not Core.finite(stats.FishCaught) then state.status="Statistik tangkapan belum tersedia."; state.snapshot=nil; return end
    local area,areaSource=location(root)
    local luck=root.LuckRevamp or {}; local pityTable=luck.PassivePity or {}
    local pity=areaSource=="current" and pityTable[area] or nil
    local stock,complete=Core.inventory(root)
    local now=os.clock()
    local sample={caught=stats.FishCaught,source=profile,now=now,timestamp=os.time(),
        location=areaSource=="current" and area or nil,pity=pity,dryStreak=luck.DryStreakSinceGoodDrop,stock=stock,stockComplete=complete,
        trading=player:GetAttribute("IsTrading")==true}
    sample.analytics={LastSecretTimestamp=(root.Analytics or {}).LastSecretTimestamp,
        LastForgottenTimestamp=(root.Analytics or {}).LastForgottenTimestamp,
        FishSinceLastSecret=(root.Analytics or {}).FishSinceLastSecret,
        FishSinceLastForgotten=(root.Analytics or {}).FishSinceLastForgotten}
    Core.observe(state.history,sample,resolve)
    state.snapshot={root=root,caught=stats.FishCaught,location=area,locationSource=areaSource,pity=pity,
        dryStreak=luck.DryStreakSinceGoodDrop,stock=stock,now=now,analytics=root.Analytics or {},
        equipment=Core.equipment(root,stock,resolve,enchant),serverLuck=shared("ServerLuck"),events=shared("Events")}
    state.status="Data diperbarui setiap 1 detik · "..Core.number(state.history.sessionCaught,0).." tangkapan sesi ini"
end
local function loadModules()
    if state.loading then return end
    state.loading=true
    local packages=RS:FindFirstChild("Packages")
    local module=packages and (packages:FindFirstChild("Replion") or packages:FindFirstChild("replion"))
    if not module and packages then
        local index=packages:FindFirstChild("_Index")
        if index then
            for _,folder in ipairs(index:GetChildren()) do
                if folder.Name:lower():find("replion",1,true) then
                    module=folder:FindFirstChild("replion") or folder:FindFirstChild("Replion")
                    if module then break end
                end
            end
        end
    end
    if module and module:IsA("ModuleScript") then
        local ok,value=boundedCall(function() return require(module) end,4)
        if ok and type(value)=="table" then addClient(value.Client or value) end
    end
    local folder=RS:FindFirstChild("Shared")
    for _,name in ipairs({"LuckConfiguration","ItemUtility","PlayerStatsUtility"}) do
        if not state.alive then state.loading=false; return end
        local target=folder and folder:FindFirstChild(name)
        if target and target:IsA("ModuleScript") then
            local ok,value=boundedCall(function() return require(target) end,4)
            if ok and type(value)=="table" then
                state.modules[name]=value
                if name=="LuckConfiguration" then state.config=value; state.liveConfig=true end
            end
        end
    end
    state.loadingFinished=true
    state.loading=false
end
local function readLuck()
    local snapshot=state.snapshot; local utility=state.modules.PlayerStatsUtility
    if not snapshot or snapshot.locationSource~="current" or not utility or type(utility.GetPlayerModifiers)~="function" then return end
    -- GetPlayerModifiers waits on these channels. Check readiness before calling it.
    if not shared("ServerLuck") or not shared("Events") then return end
    local generation=state.profile; local area=snapshot.location
    local ok,mods=boundedCall(function() return utility:GetPlayerModifiers(player,area,nil,false) end,2)
    if ok and type(mods)=="table" and Core.finite(mods.BaseLuck) and mods.BaseLuck>=1
        and generation==state.profile and state.snapshot and state.snapshot.location==area then
        state.luck={modifiers=mods,at=os.clock(),area=area,profile=generation}
        state.luck.friend=state.friend
        if type(utility.GetFriendLuck)=="function" and (not state.friendAt or os.clock()-state.friendAt>=10) then
            local friendOK,friend=boundedCall(function() return utility:GetFriendLuck(player) end,1)
            if friendOK and Core.finite(friend) then state.friend=friend; state.friendAt=os.clock(); state.luck.friend=friend end
        end
    end
end

-- Native Roblox GUI: compact cards, scrolling tabs, touch drag, minimize and close.
local colors={bg=Color3.fromRGB(13,20,33),card=Color3.fromRGB(23,34,52),line=Color3.fromRGB(43,60,80),
    text=Color3.fromRGB(233,242,251),muted=Color3.fromRGB(156,178,199),accent=Color3.fromRGB(60,214,199),warn=Color3.fromRGB(251,196,99)}
local function make(class,props,parent)
    local object=Instance.new(class)
    for key,value in pairs(props) do object[key]=value end
    object.Parent=parent; return object
end
local function round(parent,radius) make("UICorner",{CornerRadius=UDim.new(0,radius or 10)},parent) end
local function label(parent,text,size,color)
    return make("TextLabel",{BackgroundTransparency=1,Text=text,TextSize=size or 14,
        Font=Enum.Font.Gotham,TextColor3=color or colors.text,TextXAlignment=Enum.TextXAlignment.Left,
        TextYAlignment=Enum.TextYAlignment.Center,TextWrapped=true,RichText=false,Size=UDim2.new(1,0,0,38)},parent)
end
local gui=make("ScreenGui",{Name="RennFishingInsight",ResetOnSpawn=false,IgnoreGuiInset=true,DisplayOrder=90},playerGui)
state.gui=gui
local panel=make("Frame",{Name="Panel",BackgroundColor3=colors.bg,BorderSizePixel=0,
    Size=UDim2.fromOffset(480,650),Position=UDim2.fromOffset(20,48)},gui); round(panel,14)
make("UIStroke",{Color=colors.line,Thickness=1},panel)
local scale=make("UIScale",{Scale=1},panel)
local header=make("Frame",{BackgroundTransparency=1,Active=true,Size=UDim2.new(1,0,0,52)},panel)
local title=label(header,"RENN  /  FISHING INSIGHT",17,colors.accent)
title.Font=Enum.Font.GothamBold; title.Position=UDim2.fromOffset(18,6); title.Size=UDim2.new(1,-108,0,40)
local function button(parent,text,x)
    local b=make("TextButton",{Text=text,TextSize=18,Font=Enum.Font.GothamBold,TextColor3=colors.text,
        BackgroundColor3=colors.card,BorderSizePixel=0,Size=UDim2.fromOffset(32,32),Position=UDim2.new(1,x,0,10)},parent)
    round(b,8); return b
end
local minimize=button(header,"−",-86); local close=button(header,"×",-46)
local body=make("Frame",{BackgroundTransparency=1,Position=UDim2.fromOffset(0,52),Size=UDim2.new(1,0,1,-52)},panel)
local tabs=make("Frame",{BackgroundTransparency=1,Position=UDim2.fromOffset(14,0),Size=UDim2.new(1,-28,0,38)},body)
local pages,tabButtons={},{}
for index,name in ipairs({"Ringkasan","Equipment","Bonus","Riwayat"}) do
    local b=make("TextButton",{Text=name,TextSize=13,Font=Enum.Font.GothamBold,TextColor3=colors.muted,
        BackgroundColor3=colors.card,BorderSizePixel=0,Position=UDim2.new((index-1)/4,3,0,0),Size=UDim2.new(0.25,-6,1,0)},tabs)
    round(b,8); tabButtons[name]=b
    local page=make("ScrollingFrame",{Name=name,BackgroundTransparency=1,BorderSizePixel=0,
        Position=UDim2.fromOffset(14,49),Size=UDim2.new(1,-28,1,-94),ScrollBarThickness=4,
        ScrollBarImageColor3=colors.accent,CanvasSize=UDim2.fromOffset(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
        ScrollingDirection=Enum.ScrollingDirection.Y,Visible=index==1},body)
    make("UIListLayout",{Padding=UDim.new(0,10),SortOrder=Enum.SortOrder.LayoutOrder},page)
    make("UIPadding",{PaddingBottom=UDim.new(0,12),PaddingLeft=UDim.new(0,2),PaddingRight=UDim.new(0,6)},page)
    pages[name]=page
    connect(b.Activated,function()
        state.tab=name
        for key,p in pairs(pages) do p.Visible=key==name end
        if render then render() end
    end)
end
local status=label(body,state.status,11,colors.muted)
status.Position=UDim2.new(0,18,1,-39); status.Size=UDim2.new(1,-36,0,33)
status.Size=UDim2.new(1,-125,0,33)
local retry=make("TextButton",{Text="Baca ulang",TextSize=11,Font=Enum.Font.GothamBold,
    TextColor3=colors.accent,BackgroundTransparency=1,Position=UDim2.new(1,-100,1,-37),Size=UDim2.fromOffset(85,30)},body)
connect(retry.Activated,function() spawn(loadModules) end)
local order=0
local function card(page,heading)
    order+=1
    local frame=make("Frame",{BackgroundColor3=colors.card,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,LayoutOrder=order},pages[page]); round(frame,10)
    make("UIPadding",{PaddingTop=UDim.new(0,12),PaddingBottom=UDim.new(0,12),PaddingLeft=UDim.new(0,14),PaddingRight=UDim.new(0,14)},frame)
    make("UIListLayout",{Padding=UDim.new(0,6),SortOrder=Enum.SortOrder.LayoutOrder},frame)
    local h=label(frame,heading,12,colors.accent); h.Font=Enum.Font.GothamBold; h.Size=UDim2.new(1,0,0,20); h.LayoutOrder=0
    return frame
end
local function field(parent,text,size,color)
    local l=label(parent,text,size,color); l.AutomaticSize=Enum.AutomaticSize.Y
    l.Size=UDim2.new(1,0,0,size and size>=25 and 40 or 24); l.LayoutOrder=#parent:GetChildren()
    return l
end
local areaCard=card("Ringkasan","LOKASI MEMANCING")
local areaLabel=field(areaCard,"Membaca lokasi…",22)
local areaHint=field(areaCard,"",12,colors.muted)
local luckCard=card("Ringkasan","LUCK DARI STAT GAME")
local luckLabel=field(luckCard,"Menghubungkan…",32)
local luckHint=field(luckCard,"",13,colors.muted)
local pityCard=card("Ringkasan","PITY LOKASI INI")
local pityLabel=field(pityCard,"Menunggu data…",22)
local bar=make("Frame",{BackgroundColor3=colors.line,BorderSizePixel=0,Size=UDim2.new(1,0,0,7),LayoutOrder=8},pityCard); round(bar,4)
local fill=make("Frame",{BackgroundColor3=colors.accent,BorderSizePixel=0,Size=UDim2.new(0,0,1,0)},bar); round(fill,4)
local rateLabel=field(pityCard,"",13,colors.muted); rateLabel.LayoutOrder=9
local estimateLabel=field(pityCard,"",14); estimateLabel.LayoutOrder=10
local estimateHint=field(pityCard,"",12,colors.muted); estimateHint.LayoutOrder=11
local crumbCard=card("Ringkasan","DRYSTREAK & CRUMB")
local crumbLabel=field(crumbCard,"Menunggu data…",18)
local crumbEstimate=field(crumbCard,"",13,colors.muted)
local targetCard=card("Ringkasan","TARGET FORGOTTEN")
local targetLabel=field(targetCard,"Belum ada data tangkapan.",15)
local targetHint=field(targetCard,"Urutan Mythic → Secret → Forgotten tidak ditentukan oleh counter pity.",12,colors.muted)
local equipCard=card("Equipment","PERALATAN YANG DIPAKAI")
local equipFields={}
for i=1,9 do equipFields[i]=field(equipCard,"Menunggu data…",14) end
local bonusCard=card("Bonus","BONUS YANG SEDANG AKTIF")
local bonusActive=field(bonusCard,"Menunggu data…",14)
local statCard=card("Bonus","MODIFIER DARI STAT GAME")
local statFields=field(statCard,"Menunggu data…",14)
field(statCard,"Angka modifier adalah stat game. Peluang ikan dan mutasi dihitung lewat tabel drop.",12,colors.muted)
local configCard=card("Bonus","KONFIGURASI PITY")
local configLabel=field(configCard,"",14)
local configHint=field(configCard,"",12,colors.muted)
local historyCard=card("Riwayat","TANGKAPAN LANGKA TERAKHIR")
local rareFields={}
for _,tier in ipairs({6,7,8}) do rareFields[tier]=field(historyCard,"Menunggu data…",14) end
local historyHint=field(historyCard,"Nama Mythic terakhir mulai dicatat setelah GUI dibuka.",12,colors.muted)
local recentCard=card("Riwayat","HASIL LANGKA SESI INI")
local recentLabel=field(recentCard,"Belum ada hasil langka yang teridentifikasi.",14)
local names={[6]="Mythic",[7]="Secret",[8]="Forgotten"}
local function timestampText(timestamp)
    if not Core.finite(timestamp) or timestamp<=0 then return end
    local ok,value=pcall(os.date,"!%d/%m %H:%M",math.floor(timestamp)+7*3600)
    return ok and (value.." WIB") or nil
end
local function currentLuck(snapshot)
    local luck=state.luck
    if luck and os.clock()-luck.at<=4 and snapshot and snapshot.locationSource=="current" and luck.area==snapshot.location and luck.profile==state.profile then return luck end
end
local function estimateText(result)
    if result.status=="reached" then return "Counter sudah mencapai target hitung.","Target memakai angka CastsToMax dari konfigurasi. Hasil ikan tetap dihitung game." end
    if result.status=="ready" then
        local text="Sekitar "..Core.number(result.casts,0).." tangkapan menuju target poin"
        local hint=result.seconds and ("Estimasi waktu: "..Core.duration(result.seconds).." pada laju sesi ini.") or "Estimasi waktu muncul setelah laju memancing terbaca."
        return text,hint.." Ini bukan jadwal mendapat Secret atau Forgotten."
    end
    return "Estimasi muncul setelah pity bertambah.","Lanjutkan memancing agar laju poin per tangkapan terbaca."
end
render=function()
    if not state.alive then return end
    status.Text=state.status
    for name,b in pairs(tabButtons) do
        b.TextColor3=state.tab==name and colors.bg or colors.muted
        b.BackgroundColor3=state.tab==name and colors.accent or colors.card
    end
    local cfg=state.config; local target=cfg.CastsToMax or Core.defaults.CastsToMax
    configLabel.Text="Rate AFK: +"..Core.number(cfg.AFKPityRate or 0.75).." poin/tangkapan\nRate normal: +"..Core.number(cfg.PityRate or 1).." poin/tangkapan\nTarget hitung: "..Core.number(target,0).." poin\nKonfigurasi threshold reset: "..(names[cfg.ResetTierThreshold or 7] or ("tier "..Core.number(cfg.ResetTierThreshold or 7,0)))
    configHint.Text=state.liveConfig and "Konfigurasi dibaca langsung dari game." or "Konfigurasi dari pittytest.JSON, 5 Oktober 2026; konfigurasi live belum terbaca."
    local s=state.snapshot
    if not s then
        areaLabel.Text="Lokasi belum terbaca"; areaHint.Text="Menunggu data akun dari game."
        luckLabel.Text="Belum terbaca"; luckHint.Text="Menunggu stat equipment dan bonus aktif."
        pityLabel.Text="Pity belum terbaca"; fill.Size=UDim2.new(0,0,1,0)
        rateLabel.Text=""; estimateLabel.Text="Menunggu data akun."; estimateHint.Text=""
        crumbLabel.Text="DryStreak belum terbaca"; crumbEstimate.Text=""
        targetLabel.Text="Menunggu statistik Forgotten."
        bonusActive.Text="Menunggu data akun."; statFields.Text="Menunggu stat game."
        for _,l in ipairs(equipFields) do l.Text="Menunggu data akun." end
        for tier,l in pairs(rareFields) do l.Text=names[tier]..": menunggu data akun." end
        recentLabel.Text="Riwayat sesi tersimpan. Menunggu data akun terhubung kembali."
        return
    end
    areaLabel.Text=s.location or "Lokasi belum terbaca"
    areaHint.Text=s.locationSource=="current" and "Lokasi aktif dari game." or s.locationSource=="saved" and "Lokasi terakhir tersimpan; lokasi saat ini belum terbaca." or "Game belum mengirim nama lokasi."
    local luck=currentLuck(s)
    luckLabel.Text=luck and ("x"..Core.number(luck.modifiers.BaseLuck,3)) or "Belum terbaca"
    luckHint.Text=luck and ("Bonus luck +"..Core.number((luck.modifiers.BaseLuck-1)*100,1).."% · stat game saat ini") or "Stat luck belum tersedia. Equipment dan pity tetap dipantau."
    local rate,samples=Core.rate(state.history,s.locationSource=="current" and s.location or nil)
    local pace=Core.pace(state.history,os.clock())
    local estimate=Core.estimate(s.pity,target,rate,pace)
    pityLabel.Text=Core.finite(s.pity) and (Core.number(s.pity).." / "..Core.number(target,0).." poin") or "Pity lokasi ini belum tersedia"
    fill.Size=UDim2.new(estimate.progress or 0,0,1,0)
    rateLabel.Text=rate and ("Laju terukur: +"..Core.number(rate).." poin/tangkapan · "..Core.number(samples,0).." tangkapan") or "Laju poin belum terukur."
    if estimate.status=="unavailable" then
        estimateLabel.Text="Estimasi belum tersedia untuk lokasi ini."; estimateHint.Text="Lokasi aktif dan nilai pity harus terbaca terlebih dahulu."
    else estimateLabel.Text,estimateHint.Text=estimateText(estimate) end
    local dry=cfg.Crumbs and cfg.Crumbs.DryStreak or Core.defaults.Crumbs.DryStreak
    local threshold=dry.Threshold or 3000
    crumbLabel.Text=Core.finite(s.dryStreak) and (Core.number(s.dryStreak).." / "..Core.number(threshold,0).." poin") or "DryStreak belum terbaca"
    -- DryStreak has its own measured rate; do not borrow a map's pity rate.
    local dryEstimate=Core.estimate(s.dryStreak,threshold,state.dryRate,pace)
    crumbEstimate.Text=dryEstimate.status=="reached" and ("Ambang tercapai. Konfigurasi kesempatan crumb: "..Core.number((dry.ChancePerCast or 0)*100,0).."% per tangkapan.")
        or dryEstimate.casts and ("Sekitar "..Core.number(dryEstimate.casts,0).." tangkapan menuju ambang kesempatan crumb.")
        or "Laju DryStreak sedang diukur."
    for i,row in ipairs(s.equipment) do equipFields[i].Text=row.label.."\n"..row.value end
    local active={}
    local server=s.serverLuck
    active[#active+1]="Server luck: "..(server and Core.finite(server.ServerMultiplier) and ("x"..Core.number(server.ServerMultiplier)) or "belum terbaca")
    local settings=s.root.Settings or {}
    active[#active+1]="Friend luck: "..(settings["Friend Luck"]==false and "dimatikan" or luck and Core.finite(luck.friend) and ("+"..Core.number(luck.friend*100,0).."%") or "belum terbaca")
    local ability=s.equipment[9]; active[#active+1]="Ability: "..ability.value
    local potions={}
    for _,p in pairs(s.root.EquippedPotions or {}) do if type(p)=="table" then potions[#potions+1]=Core.definitionName(resolve("Potions",p.Id),"Potion #"..tostring(p.Id)) end end
    active[#active+1]="Potion: "..(#potions>0 and table.concat(potions,", ") or "tidak ada yang dipakai")
    local events=s.events and s.events.Events
    active[#active+1]="Event: "..(type(events)=="table" and (#events>0 and table.concat(events,", ") or "tidak ada event aktif") or "belum terbaca")
    active[#active+1]="Totem: "..Core.number(#(s.root.TotemBoosts or {}),0).." boost tercatat"
    bonusActive.Text=table.concat(active,"\n\n")
    local lines={}
    if luck then
        local mods=luck.modifiers
        for _,pair in ipairs({{"SECRETMultiplier","Stat Secret"},{"FORGOTTENMultiplier","Stat Forgotten"},
            {"MutationMultiplier","Stat mutasi"},{"ShinyMultiplier","Stat shiny"},{"ReelMultiplier","Stat reel"},
            {"XPMultiplier","Stat XP"},{"SpecialLuckMultiplier","Tambahan multiplier server"}}) do
            if Core.finite(mods[pair[1]]) then lines[#lines+1]=pair[2]..": "..(pair[1]=="SpecialLuckMultiplier" and "+" or "x")..Core.number(mods[pair[1]],3) end
        end
    end
    lines[#lines+1]="Bonus pity dalam luck: game belum menyediakan nilainya."
    statFields.Text=table.concat(lines,"\n\n")
    local analytics=s.analytics
    for tier,l in pairs(rareFields) do
        local rare=Core.rareSummary(state.history,tier,s.caught,analytics,s.locationSource=="current" and s.location or nil)
        local time=timestampText(tier==7 and analytics.LastSecretTimestamp or tier==8 and analytics.LastForgottenTimestamp)
        local first=names[tier].." terakhir teridentifikasi: "..(rare.last and rare.last.name or "nama ikan belum tersedia")
        local detail=rare.last and ("Lokasi: "..(rare.last.location or "belum terbaca")) or time and ("Waktu terakhir dari akun: "..time) or "Belum tercatat sejak GUI dibuka."
        if rare.since then detail=detail.."\n"..Core.number(rare.since,0).." tangkapan sejak "..names[tier].." terakhir." end
        if rare.averageGap then detail=detail.."\nRata-rata jarak di "..s.location..": "..Core.number(rare.averageGap,1).." tangkapan ("..rare.intervalCount.." interval sesi)." end
        l.Text=first.."\n"..detail
    end
    local forgotten=Core.rareSummary(state.history,8,s.caught,analytics,s.locationSource=="current" and s.location or nil)
    if forgotten.averageGap then
        targetLabel.Text="Rata-rata jarak Forgotten di "..s.location..": "..Core.number(forgotten.averageGap,1).." tangkapan."
        targetHint.Text="Waktu untuk satu jarak rata-rata: "..(pace and Core.duration(forgotten.averageGap*pace) or "menunggu laju memancing")..". Rata-rata ini tidak menetapkan tangkapan berikutnya."
    else
        targetLabel.Text=forgotten.since and (Core.number(forgotten.since,0).." tangkapan sejak Forgotten terakhir.") or "Forgotten terakhir belum tercatat."
        targetHint.Text="Estimasi jarak memerlukan 3 Forgotten pada periode memancing di lokasi yang sama. Peluang tangkapan berikutnya belum tersedia."
    end
    historyHint.Text="Sesi: "..Core.number(state.history.sessionCaught,0).." tangkapan · "..Core.number(state.history.classified,0).." ikan teridentifikasi · "..Core.number(state.history.unknown,0).." hasil belum teridentifikasi."
    local recent={}
    for i=#state.history.rare,math.max(1,#state.history.rare-9),-1 do
        local r=state.history.rare[i]
        recent[#recent+1]=names[r.tier].." · "..r.name.."\n"..(r.location or "Lokasi belum terbaca").." · "..(timestampText(r.timestamp) or "sesi ini")
    end
    recentLabel.Text=#recent>0 and table.concat(recent,"\n\n") or "Belum ada hasil langka yang teridentifikasi dalam sesi ini."
end
connect(close.Activated,state.Close)
connect(minimize.Activated,function()
    state.minimized=not state.minimized; body.Visible=not state.minimized
    panel.Size=UDim2.fromOffset(480,state.minimized and 52 or 650); minimize.Text=state.minimized and "+" or "−"
end)
local function viewport()
    local camera=workspace.CurrentCamera
    local size=camera and camera.ViewportSize
    return size and size.X>0 and size.Y>0 and size or Vector2.new(900,700)
end
local function fit()
    local size=viewport(); scale.Scale=math.min(1,(size.X-24)/480,(size.Y-24)/650)
    if scale.Scale<=0 then scale.Scale=0.5 end
    panel.Position=UDim2.fromOffset(math.clamp(panel.Position.X.Offset,8,math.max(8,size.X-480*scale.Scale-8)),
        math.clamp(panel.Position.Y.Offset,8,math.max(8,size.Y-(state.minimized and 52 or 650)*scale.Scale-8)))
end
local drag
connect(header.InputBegan,function(input)
    if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
        drag={input=input,start=input.Position,x=panel.Position.X.Offset,y=panel.Position.Y.Offset}
    end
end)
connect(UIS.InputChanged,function(input)
    if drag and (input==drag.input or input.UserInputType==Enum.UserInputType.MouseMovement) then
        local delta=input.Position-drag.start
        panel.Position=UDim2.fromOffset(drag.x+delta.X,drag.y+delta.Y); fit()
    end
end)
connect(UIS.InputEnded,function(input) if drag and input==drag.input then drag=nil end end)
if workspace.CurrentCamera then connect(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"),fit) end
fit(); render(); trackers()
spawn(loadModules)
spawn(function()
    local previousDry
    while state.alive do
        local old=state.snapshot
        local ok,err=pcall(poll)
        if not ok then state.lastError=tostring(err); state.status="Pembacaan tertunda. Mencoba lagi…"; state.snapshot=nil end
        local s=state.snapshot
        if not s or not old or s.root~=old.root then state.dryRate=nil end
        if s and Core.finite(s.dryStreak) and Core.finite(previousDry) and s.dryStreak<previousDry then state.dryRate=nil end
        if s and old and s.root==old.root and s.caught>old.caught and Core.finite(s.dryStreak) and Core.finite(previousDry) then
            local delta=s.dryStreak-previousDry
            if delta>0 then state.dryRate=delta/(s.caught-old.caught)
            elseif delta<0 then state.dryRate=nil end
        end
        previousDry=s and s.dryStreak or nil
        local rendered,renderErr=pcall(render)
        if not rendered then state.lastError=tostring(renderErr); status.Text="Tampilan tertunda. Tekan Baca ulang." end
        task.wait(1)
    end
end)
spawn(function() while state.alive do readLuck(); if state.alive then render() end; task.wait(1) end end)
