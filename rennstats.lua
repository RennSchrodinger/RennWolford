-- RennStats 1.9 | incremental inventory collector and website-controlled trade.
-- Backup: lua/backups/renn-inventory-before-rennstats-20261004.lua
-- Set getgenv()._rennkey before executing. API: https://rennstats.rennhsg.my.id.
local Core = (function()
    local M = {}
    local idFields = { "Id", "ID", "ItemId", "ItemID", "id", "itemId" }
    local nameFields = { "Name", "name", "ItemName", "DisplayName" }
    local iconFields = { "Icon", "icon", "Image", "ImageId", "ImageID", "IconId", "IconID", "IconAssetId", "TextureId", "Thumbnail" }
    local qtyFields = { "Quantity", "quantity", "Amount", "amount", "Count", "count", "Qty", "qty", "Stack" }
    local uniqueFields = { "UUID", "Uuid", "uuid", "Uid", "UID", "UniqueId" }
    local tradeFields = {"Tradable", "Tradeable", "IsTradable", "IsTradeable", "CanTrade", "RAP", "Rap", "rap", "RecentAveragePrice"}
    local function tradeData(value)
        local result = {}
        for _, source in ipairs({type(value.TradeData) == "table" and value.TradeData or {}, value,
            type(value.Data) == "table" and value.Data or {}, type(value.Metadata) == "table" and value.Metadata or {},
            type(value.Meta) == "table" and value.Meta or {}}) do
            for _, field in ipairs(tradeFields) do
                if result[field] == nil and (type(source[field]) == "number" or type(source[field]) == "boolean") then result[field] = source[field] end
            end
        end
        return result
    end
    local secondaryEnchantFields = {"SecondEnchantments", "SecondEnchantId", "SecondEnchantmentId", "SecondEnchant",
        "SecondEnchantment", "EnchantId2", "EnchantmentId2", "Enchant2", "Enchantment2", "SecondaryEnchant", "SecondaryEnchantId"}
    local mutationFields = {"Variant", "variant", "VariantId", "variantId", "VariantIds", "variantIds", "Mutation", "mutation",
        "MutationId", "mutationId", "Mutations", "mutations", "MutationIds", "mutationIds"}
    local function clean(value)
        return tostring(value or ""):match("^%s*(.-)%s*$") or ""
    end
    local function normalized(value)
        return clean(value):lower():gsub("[%s_%-]", "")
    end
    local aliases = {
        fish = "Fish", fishes = "Fish", fishingrod = "Fishing Rods", fishingrods = "Fishing Rods",
        rod = "Fishing Rods", rods = "Fishing Rods", bait = "Baits", baits = "Baits",
        gear = "Gears", gears = "Gears", enchantstone = "Enchant Stones", enchantstones = "Enchant Stones",
        pet = "Pets", pets = "Pets", petegg = "Pet Eggs", peteggs = "Pet Eggs",
        boat = "Boats", boats = "Boats", lantern = "Lanterns", lanterns = "Lanterns",
        emote = "Emotes", emotes = "Emotes", halo = "Halos", halos = "Halos",
        charm = "Charms", charms = "Charms", cosmetic = "Cosmetics", cosmetics = "Cosmetics",
        potion = "Potions", potions = "Potions", totem = "Totems", totems = "Totems",
        booth = "Booths", booths = "Booths", finisher = "Finishers", finishers = "Finishers",
        ability = "Abilities", abilities = "Abilities", trophy = "Trophies", trophies = "Trophies", thropies = "Trophies",
        seed = "Seeds", seeds = "Seeds", crop = "Crops", crops = "Crops", plant = "Plants", plants = "Plants",
    }
    function M.uploadRanges(raw, size)
        local ranges, first, length = {}, 1, #raw
        while first <= length do
            local last = math.min(first + size - 1, length)
            if last < length then
                while last >= first do
                    local byte = string.byte(raw, last + 1)
                    if byte < 128 or byte >= 192 then break end
                    last = last - 1
                end
            end
            assert(last >= first, "Ukuran chunk terlalu kecil")
            table.insert(ranges, {first, last}); first = last + 1
        end
        return ranges
    end
    -- Encode containers incrementally; native JSONEncode sees only scalar values.
    -- Chunks never split UTF-8, and no second full-size JSON string is allocated.
    function M.jsonChunks(value, encodeScalar, checkpoint, size)
        size = size or 196608
        local chunks, pieces, length, total, active = {}, {}, 0, 0, {}
        local function flush()
            if length > 0 then table.insert(chunks, table.concat(pieces)); pieces = {}; length = 0 end
        end
        local function append(text)
            local first = 1
            while first <= #text do
                if checkpoint then checkpoint() end
                local last = math.min(#text, first + size - length - 1)
                while last < #text and last >= first and string.byte(text,last+1) >= 128 and string.byte(text,last+1) < 192 do last -= 1 end
                if last < first then flush(); continue end
                local part = text:sub(first,last)
                table.insert(pieces,part); length += #part; total += #part
                if total > 67108864 then error("Snapshot melebihi 64 MB") end
                first = last + 1
                if length >= size - 3 then flush() end
            end
        end
        local function write(child, depth)
            if checkpoint then checkpoint() end
            if type(child) ~= "table" then append(encodeScalar(child)); return end
            assert(depth <= 64 and not active[child], "JSON cyclic/terlalu dalam")
            active[child] = true
            local count, array = 0, true
            for key in pairs(child) do
                if checkpoint then checkpoint() end
                count += 1
                if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then array = false end
            end
            array = array and count == #child
            append(array and "[" or "{")
            local index = 0
            if array then
                for _, item in ipairs(child) do
                    if index > 0 then append(",") end; index += 1; write(item, depth + 1)
                end
            else
                for key, item in pairs(child) do
                    if index > 0 then append(",") end; index += 1
                    append(encodeScalar(tostring(key))); append(":"); write(item, depth + 1)
                end
            end
            append(array and "]" or "}"); active[child] = nil
        end
        write(value, 0); flush()
        return chunks, total
    end
    function M.dataEqual(a, b, checkpoint, seen)
        if a == b then return true end
        if type(a) ~= "table" or type(b) ~= "table" then return false end
        seen = seen or {}
        if seen[a] then return seen[a] == b end
        seen[a] = b
        for key, value in pairs(a) do
            if checkpoint then checkpoint() end
            if not M.dataEqual(value, b[key], checkpoint, seen) then return false end
        end
        for key in pairs(b) do if a[key] == nil then return false end end
        return true
    end
    function M.reportDelta(previous, current, checkpoint)
        local function changes(before, after)
            local old, present, result = {}, {}, {upsert={},remove={},order={}}
            for _, row in ipairs(before) do old[row.key] = row; if checkpoint then checkpoint() end end
            for _, row in ipairs(after) do
                if checkpoint then checkpoint() end
                present[row.key] = true
                table.insert(result.order,row.key)
                local prior = old[row.key]
                if not M.dataEqual(prior, row, checkpoint) then
                    local update = table.clone(row)
                    if prior and type(prior.instances) == "table" and type(row.instances) == "table" then
                        local a, b, add, remove, expected = {}, {}, {}, {}, {}
                        for _, id in ipairs(prior.instances) do a[id] = true; if checkpoint then checkpoint() end end
                        for _, id in ipairs(row.instances) do
                            b[id] = true; if not a[id] then table.insert(add,id) end; if checkpoint then checkpoint() end
                        end
                        for _, id in ipairs(prior.instances) do
                            if not b[id] then table.insert(remove,id) else table.insert(expected,id) end
                            if checkpoint then checkpoint() end
                        end
                        for _, id in ipairs(add) do table.insert(expected,id) end
                        if #add + #remove < #row.instances and M.dataEqual(expected,row.instances,checkpoint) then
                            update.instances = nil; update.instancesPatch = {add=add,remove=remove}
                        end
                    end
                    table.insert(result.upsert, update)
                end
            end
            for _, row in ipairs(before) do
                if not present[row.key] then table.insert(result.remove,row.key) end
                if checkpoint then checkpoint() end
            end
            return result
        end
        local header = table.clone(current); header.inventory = table.clone(current.inventory)
        header.inventory.rows = nil; header.choices = nil
        return {schema="rennstats/delta-v1",baseRevision=previous.revision,revision=current.revision, snapshot=header,
            rows=changes(previous.inventory.rows,current.inventory.rows), choices=changes(previous.choices,current.choices)}
    end
    function M.category(value)
        local text = clean(value)
        return aliases[normalized(text)] or (text ~= "" and text or "Uncategorized")
    end
    function M.catalogCategory(value)
        return aliases[normalized(value)]
    end
    function M.catalogPaths()
        local paths = {}
        -- Limit discovery to definition roots; never require every client/game module.
        for _, prefix in ipairs({{}, {"Modules"}, {"Shared"}, {"Shared", "Modules"}, {"Configs"}, {"Definitions"}, {"Catalogs"}}) do
            for _, name in ipairs({"Items", "Fish", "FishingRods", "Fishing Rods", "Rods", "Baits", "Abilities", "Ability",
                "Trophies", "Gears", "EnchantStones", "Enchant Stones", "Boats", "Charms", "Emotes", "Halos",
                "Lanterns", "Pets", "PetEggs", "Pet Eggs", "Potions", "Totems", "Booths", "Finishers", "Cosmetics"}) do
                local path = table.clone(prefix); table.insert(path, name); table.insert(paths, path)
            end
        end
        return paths
    end
    function M.icon(value)
        if type(value) ~= "string" and type(value) ~= "number" then return "" end
        local text = clean(value)
        if text:match("^%d+$") then
            return tonumber(text) > 0 and "rbxassetid://" .. text or ""
        end
        if text:match("^rbxassetid://%d+$") then
            return tonumber(text:match("(%d+)$")) > 0 and text or ""
        end
        if text:match("^rbxasset://") or text:match("^rbxthumb://") then return text end
        local asset = text:match("[?&]id=(%d+)")
        if asset and text:lower():find("roblox.com/", 1, true) then return "rbxassetid://" .. asset end
        -- Arbitrary HTTPS CDN URLs cannot reliably be used as Roblox ImageLabel content.
        return ""
    end
    local function first(record, fields)
        if type(record) ~= "table" then return nil end
        for _, field in ipairs(fields) do
            if record[field] ~= nil then return record[field] end
        end
        return nil
    end
    M.first = first
    -- A forced read requested while normalization yields must run after that read.
    function M.beginRefresh(state, force)
        if not state.alive or (state.paused and not force) then return false end
        if state.busy then
            if force then state.pendingRefresh = true; state.pendingForcedRefresh = true end
            return false
        end
        state.busy = true
        return true
    end
    function M.endRefresh(state)
        state.busy = false
        local pending = state.alive and state.pendingRefresh == true
        local forced = state.pendingForcedRefresh == true
        state.pendingForcedRefresh = false
        state.pendingRefresh = false
        return pending, forced
    end
    function M.catalogDiagnostics(state, now)
        local elapsed = state.catalogStarted and math.max(0, (state.catalogFinished or now) - state.catalogStarted) or 0
        return table.concat({
            "Catalog ready: " .. tostring(state.catalogReady == true) .. " | tahap: " .. tostring(state.catalogPhase or "Menunggu"),
            "Catalog: " .. tostring(state.catalog.count) .. " item; gagal require: " .. tostring(state.catalogFailures or 0),
            "Modul katalog diperiksa: " .. tostring(state.catalogModules or 0) .. " | durasi: " .. tostring(math.floor(elapsed)) .. " detik",
            "Modul katalog aktif: " .. tostring(state.catalogModule or "Tidak ada"),
            "Pemetaan nama mutasi: " .. tostring(state.mutationCount or 0) .. "; gagal require label: " .. tostring(state.catalogLabelFailures or 0),
            "Cache definisi sesi: " .. tostring(state.definitionCacheHits or 0) .. " hit; lookup ID: " .. tostring(state.definitionLookups or 0),
            "Catalog error: " .. tostring(state.catalogError or "Tidak ada") .. " | require gagal terakhir: " .. tostring(state.catalogLastFailure or "Tidak ada"),
            "Root katalog ditemukan:\n" .. table.concat(state.catalogRoots or {}, "\n"),
            "Pemrosesan terakhir (ms, termasuk jeda): capture=" .. tostring(state.captureMs or 0)
                .. "; normalisasi=" .. tostring(state.normalizeMs or 0) .. "; equipment=" .. tostring(state.equipmentMs or 0)
                .. "; cache stok=" .. tostring(state.bagMs or 0) .. "; JSON=" .. tostring(state.reportEncodeMs or 0),
            "Ukuran laporan terakhir: " .. tostring(state.reportBytes or 0) .. " byte; node capture=" .. tostring(state.captureNodes or 0),
        }, "\n")
    end
    function M.uuid(value)
        if type(value) ~= "string" then return nil end
        local text = clean(value):lower()
        if text:sub(1, 1) == "{" and text:sub(-1) == "}" then text = text:sub(2, -2) end
        if #text ~= 36 then return nil end
        local a, b, c, d, e = text:match("^(%x+)%-(%x+)%-(%x+)%-(%x+)%-(%x+)$")
        if a and #a == 8 and #b == 4 and #c == 4 and #d == 4 and #e == 12
            and c:sub(1, 1) == "4" and d:sub(1, 1):match("[89ab]") then return text end
        return nil
    end
    -- Older package builds and executor module loaders may expose different call styles.
    function M.clientLookup(client, channel)
        if type(client) ~= "table" or type(client.GetReplion) ~= "function" then return nil end
        local ok, value = pcall(client.GetReplion, client, channel)
        if ok and type(value) == "table" and not value.Destroyed then return value, "colon" end
        local dotOK, dotValue = pcall(client.GetReplion, channel)
        if dotOK and type(dotValue) == "table" and not dotValue.Destroyed then return dotValue, "dot" end
        -- One valid nil result is a missed channel; two exceptions are an API failure.
        if ok or dotOK then return nil, "nil" end
        return nil, "error", "colon: " .. tostring(value) .. " | dot: " .. tostring(dotValue)
    end
    function M.clientReplion(client, channel)
        return M.clientLookup(client, channel)
    end
    function M.resolveClient(value)
        if type(value) ~= "table" then return nil end
        for _, candidate in ipairs({ value.Client or false, value.client or false, value }) do
            if type(candidate) == "table" and (type(candidate.GetReplion) == "function"
                or type(candidate.GetReplions) == "function" or type(candidate.WaitReplion) == "function") then return candidate end
        end
        return nil
    end
    function M.requireLoaders(wrapped, getRuntime)
        local loaders = { { name = "executor require", call = wrapped } }
        if type(getRuntime) == "function" then
            local ok, runtime = pcall(getRuntime)
            local native = ok and type(runtime) == "table" and runtime.require
            if type(native) == "function" and native ~= wrapped then
                table.insert(loaders, { name = "runtime require", call = native })
            end
        end
        return loaders
    end
    function M.cacheReader(api, topLevel)
        if type(topLevel) == "function" then return topLevel, "getupvalues" end
        if type(api) == "table" and type(api.getupvalues) == "function" then return api.getupvalues, "debug.getupvalues" end
        if type(api) == "table" and type(api.getupvalue) == "function" then
            return function(callback)
                local results = {}
                for index = 1, 16 do
                    local ok, name, value = pcall(api.getupvalue, callback, index)
                    if not ok then
                        if index == 1 then error(name) end
                        break
                    end
                    if name == nil then break end
                    local candidate = value ~= nil and value or name
                    if type(candidate) == "table" then table.insert(results, candidate) end
                end
                return results
            end, "debug.getupvalue"
        end
        return nil, "Tidak tersedia"
    end
    function M.cacheReaders(apis, globals)
        local readers, seen = {}, {}
        local function add(fn, name, single)
            if type(fn) ~= "function" or seen[fn] then return end
            seen[fn] = true
            local call = single and M.cacheReader({getupvalue = fn}) or fn
            table.insert(readers, {call = call, name = name, source = fn})
        end
        globals = globals or {}
        add(globals.getupvalues, "getupvalues")
        add(globals.getupvalue, "getupvalue", true)
        for index, api in ipairs(apis or {}) do
            if type(api) == "table" then
                add(api.getupvalues, "debug[" .. index .. "].getupvalues")
                add(api.getupvalue, "debug[" .. index .. "].getupvalue", true)
            end
        end
        return readers
    end
    function M.probeCacheReader(reader)
        -- This function has one known table upvalue. It never calls a game function.
        local marker = {}
        local function target() return marker end
        local ok, values = pcall(reader.call, target)
        if not ok then return {status = "error", tables = 0, reason = tostring(values)} end
        if type(values) ~= "table" then return {status = "failed", tables = 0, reason = "Hasil API bukan tabel"} end
        local count = 0
        for _, value in pairs(values) do
            if rawequal(value, marker) then
                return {status = "passed", tables = count + 1, reason = "Upvalue tabel uji terbaca dengan identitas yang tepat"}
            end
            if type(value) == "table" then count = count + 1 end
        end
        return {status = "failed", tables = count, reason = "API tidak mengembalikan upvalue tabel yang diketahui ada"}
    end
    function M.guiRecord(facts, catalog)
        local attributes = facts.attributes or {}
        local uid = M.uuid(facts.name) or M.uuid(first(attributes, { "UUID", "Uuid", "uuid", "Uid", "UniqueId", "ItemUUID" }))
        if not uid and not facts.allowAnonymous then return nil end
        local name = first(attributes, nameFields)
        local id = first(attributes, idFields)
        local category = attributes.Type or attributes.ItemType or attributes.Category
        local entry = M.lookup(catalog, id, name, category)
        local meta, extra, namedEntries, quantity = {}, {}, {}, first(attributes, qtyFields)
        for _, field in ipairs(mutationFields) do if attributes[field] ~= nil then meta[field] = attributes[field] end end
        if attributes.Modifier ~= nil then meta.Mutation = meta.Mutation or attributes.Modifier end
        local labels = {}
        for _, label in ipairs(facts.labels or {}) do
            table.insert(labels, label)
            if label.text:find("\n", 1, true) then
                for line in label.text:gmatch("[^\r\n]+") do table.insert(labels, { name = label.name, text = line }) end
            end
        end
        local function labelPriority(label)
            local name = tostring(label.name):lower()
            return (name == "name" or name == "title" or name == "itemname" or name == "displayname") and 1 or 0
        end
        table.sort(labels, function(a, b) return labelPriority(a) > labelPriority(b) end)
        for _, label in ipairs(labels) do
            local text = clean(label.text):gsub("<[^>]*>", "")
            local candidate = text:gsub("\n", " ")
            for _ = 1, 3 do
                local stripped = false
                for _, flag in ipairs({ "Shiny", "Big", "Mega" }) do
                    if candidate:sub(1, #flag + 1):lower() == flag:lower() .. " " then
                        meta[flag] = true; candidate = candidate:sub(#flag + 2); stripped = true
                    end
                end
                if not stripped then break end
            end
            local labelName = tostring(label.name):lower()
            local mutationLabel = labelName:find("mutation", 1, true) or labelName:find("variant", 1, true)
                or labelName:find("modifier", 1, true)
            local mappedMutation = catalog.mutationNames and catalog.mutationNames[normalized(text)]
            local match = not mutationLabel and (not mappedMutation or not entry or labelPriority(label) == 1)
                and M.lookup(catalog, nil, candidate, category)
            if not match and not mutationLabel and labelPriority(label) == 1 then
                local suffixMatch, suffixName
                for _, mutationName in pairs(catalog.mutationNames or {}) do
                    local suffix = " " .. mutationName
                    if candidate:sub(-#suffix):lower() == suffix:lower() then
                        local base = M.lookup(catalog, nil, candidate:sub(1, -#suffix - 1), category)
                        if base and (not suffixName or #mutationName > #suffixName) then suffixMatch = base; suffixName = mutationName end
                    end
                end
                if suffixMatch then
                    match = suffixMatch; meta.Mutations = meta.Mutations or {}; meta.Mutations[suffixName] = true
                end
            end
            if match then
                namedEntries[match.key] = true; entry = match; name = match.name
            end
            local number, suffix = text:lower():gsub(",", ""):match("^(%d+%.?%d*)%s*([kmb]?)%s*kg$")
            if number then
                meta.Weight = tonumber(number) * ({ k = 1000, m = 1000000, b = 1000000000, [""] = 1 })[suffix]
                local decimals = #(number:match("%.(%d+)") or "")
                meta.WeightResolution = ({ k = 1000, m = 1000000, b = 1000000000, [""] = 1 })[suffix] / 10 ^ decimals
            end
            if mutationLabel or (mappedMutation and not match) then
                meta.Mutations = meta.Mutations or {}
                if type(meta.Mutation) == "string" or type(meta.Mutation) == "number" then meta.Mutations[meta.Mutation] = true end
                meta.Mutations[mappedMutation or text] = true
                meta.Mutation = nil -- All recognized mutation labels stay available as a set.
            end
            if label.name and (label.name:lower() == "itemname" or label.name:lower() == "displayname") and not name then name = candidate end
            local stack = text:match("^[xX]%s*(%d+)$") or text:match("^(%d+)%s*[xX]$") or text:match("^(%d+)$")
            if stack and label.name and (label.name:lower():find("amount", 1, true)
                or label.name:lower():find("quantity", 1, true) or label.name:lower():find("count", 1, true)) then quantity = tonumber(stack) end
            table.insert(extra, text)
        end
        local nameCount = 0; for _ in pairs(namedEntries) do nameCount = nameCount + 1 end
        if nameCount > 1 then return nil end -- An ancestor containing several cards is not one item.
        local icon = M.icon(first(attributes, iconFields))
        if icon == "" and entry then icon = entry.icon end
        for _, value in ipairs(facts.images or {}) do
            if icon == "" or value.name:lower() == "itemicon" or value.name:lower() == "icon" then
                local image = M.icon(value.image); if image ~= "" then icon = image end
            end
        end
        if not uid then
            local realImage = false
            for _, value in ipairs(facts.images or {}) do if M.icon(value.image) ~= "" then realImage = true; break end end
            if not entry or not realImage or facts.truncated then return nil end
        end
        if not name and not entry and not id then return nil end
        return { UUID = uid, Id = id or (entry and entry.id), Name = name or (entry and entry.name),
            Type = category or (entry and entry.category), Icon = icon, Quantity = quantity, Metadata = meta,
            GuiPath = facts.path, Reader = "GUI", UUIDUnavailable = not uid,
            GuiText = table.concat(extra, " | ") }
    end
    function M.clientCandidates(client, channels, getUpvalues)
        local results, seen = {}, {}
        local diagnostics = {lookups = 0, emptyLookups = 0, lookupErrors = 0, cacheReads = 0,
            cacheTables = 0, cacheErrors = 0, cacheCandidates = 0, cacheNotes = {}}
        local function add(value, origin)
            if type(value) == "table" and not value.Destroyed and not seen[value]
                and (type(value.Data) == "table" or type(value.Get) == "function") then
                seen[value] = true; table.insert(results, { value = value, origin = origin })
            end
        end
        local seenChannels = {}
        for _, channel in ipairs(channels) do
            if not seenChannels[channel] then
                seenChannels[channel] = true; diagnostics.lookups = diagnostics.lookups + 1
                local value, mode, err = M.clientLookup(client, channel)
                add(value, tostring(channel))
                if not value then
                    if mode == "error" then diagnostics.lookupErrors = diagnostics.lookupErrors + 1; diagnostics.lastLookupError = err
                    else diagnostics.emptyLookups = diagnostics.emptyLookups + 1 end
                end
            end
        end
        for _, field in ipairs({"Replions", "_replions", "Cache", "_cache", "cache"}) do
            local cache = client[field]
            if type(cache) == "table" then
                local count = 0
                for key, value in next, cache do
                    count = count + 1; if count > 64 then break end
                    add(value, "Client." .. field .. ":" .. tostring(key))
                end
            end
        end
        if type(client.GetReplions) == "function" then
            local ok, values = pcall(client.GetReplions, client)
            if not ok or type(values) ~= "table" then ok, values = pcall(client.GetReplions) end
            if ok and type(values) == "table" then
                local count = 0
                for key, value in pairs(values) do
                    count = count + 1; if count > 64 then break end
                    add(value, "GetReplions:" .. tostring(key))
                end
            end
        end
        -- Read only cache upvalues of this Client's lookup functions. Never invoke waiting APIs.
        local readers = type(getUpvalues) == "function" and {{call = getUpvalues, name = "upvalues"}} or getUpvalues or {}
        local targets, targetSeen = {}, {}
        for _, field in ipairs({"GetReplion", "WaitReplion", "AwaitReplion"}) do
            if type(client[field]) == "function" and not targetSeen[client[field]] then
                targetSeen[client[field]] = true; table.insert(targets, {call = client[field], name = field})
            end
        end
        for _, reader in ipairs(readers) do
            local remaining = 256
            for _, target in ipairs(targets) do
                diagnostics.cacheReads = diagnostics.cacheReads + 1
                local ok, upvalues = pcall(reader.call, target.call)
                local tables, found = 0, 0
                if ok and type(upvalues) == "table" then
                    for _, cache in pairs(upvalues) do
                        if type(cache) == "table" then
                            tables = tables + 1
                            for key, value in next, cache do
                                remaining = remaining - 1; if remaining < 0 then break end
                                if type(value) == "table" and type(value._channel) == "string"
                                    and (type(value.Get) == "function" or type(value.Data) == "table") then
                                    local before = #results
                                    add(value, "client cache:" .. target.name .. ":" .. tostring(key))
                                    if #results > before then found = found + 1 end
                                end
                            end
                        end
                        if remaining < 0 then break end
                    end
                    diagnostics.cacheTables = diagnostics.cacheTables + tables
                    diagnostics.cacheCandidates = diagnostics.cacheCandidates + found
                else
                    diagnostics.cacheErrors = diagnostics.cacheErrors + 1
                end
                table.insert(diagnostics.cacheNotes, reader.name .. "/" .. target.name .. ": " ..
                    ((ok and type(upvalues) == "table") and (tables .. " tabel; " .. found .. " replion baru")
                    or ("gagal: " .. tostring(upvalues))))
            end
        end
        return results, diagnostics
    end
    function M.guiCards(candidates)
        table.sort(candidates, function(a, b)
            if (a.record.UUID ~= nil) ~= (b.record.UUID ~= nil) then return a.record.UUID ~= nil end
            return #(a.ancestors or {}) > #(b.ancestors or {})
        end)
        local records, kept, ancestors, uuids = {}, {}, {}, {}
        for _, candidate in ipairs(candidates) do
            local duplicate = kept[candidate.id] or ancestors[candidate.id]
            for _, parent in ipairs(candidate.ancestors or {}) do if kept[parent] then duplicate = true; break end end
            local uid = candidate.record.UUID
            if uid and uuids[uid] then duplicate = true end
            if not duplicate then
                kept[candidate.id] = true
                for _, parent in ipairs(candidate.ancestors or {}) do ancestors[parent] = true end
                if uid then uuids[uid] = true end
                table.insert(records, candidate.record)
            end
        end
        return records
    end
    function M.guiScope(facts)
        if not facts.localPlayerGui then return false, "Area GUI bukan PlayerGui akun lokal" end
        if not facts.selectedList then return false, "Pilih daftar tas secara eksplisit" end
        if facts.blocked then return false, "Area papan peringkat/katalog/shop/trade bukan isi tas" end
        if not facts.visible and not facts.confirmedList then return false, "Daftar tas atau parent-nya tersembunyi" end
        return true, "Daftar tas dipilih pengguna"
    end
    function M.blockedGuiName(name)
        name = tostring(name):lower()
        for _, word in ipairs({ "template", "equipped", "hotbar", "shop", "store", "reward", "trade", "craft",
            "index", "encyclopedia", "highscore", "leaderboard", "ranking" }) do
            if name:find(word, 1, true) then return true end
        end
        return false
    end
    function M.guiHitList(hit, localPlayerGui, ownGui)
        if not hit:IsDescendantOf(localPlayerGui) or (ownGui and hit:IsDescendantOf(ownGui)) then return nil end
        local cursor, scrolling = hit, nil
        while cursor and cursor ~= localPlayerGui do
            if M.blockedGuiName(cursor.Name) then return nil, "Panel ini papan peringkat/katalog, bukan tas" end
            if cursor:IsA("GuiObject") and not cursor.Visible then return nil, "Panel yang diklik tersembunyi" end
            if cursor:IsA("ScreenGui") and not cursor.Enabled then return nil, "Panel yang diklik tidak aktif" end
            if not scrolling and cursor:IsA("ScrollingFrame") then scrolling = cursor end
            cursor = cursor.Parent
        end
        return scrolling
    end
    function M.guiItemScope(node, selected)
        local cursor = node
        while cursor and cursor ~= selected do
            if M.blockedGuiName(cursor.Name) then return false end
            if cursor:IsA("GuiObject") and not cursor.Visible then return false end
            cursor = cursor.Parent
        end
        -- The confirmed list/outer window may be closed; hidden cards within it still stay excluded.
        return cursor ~= nil and cursor == selected
    end
    function M.profileScope(data, localUserId, channel, replicateAll, channels)
        if type(data) ~= "table" then return false, "Profile bukan tabel" end
        local sources = { data, type(data.Profile) == "table" and data.Profile or false,
            type(data.Data) == "table" and data.Data or false }
        local owned = false
        for _, value in ipairs(sources) do
            if type(value) == "table" then
                for _, field in ipairs({ "UserId", "OwnerUserId", "PlayerUserId" }) do
                    if value[field] ~= nil then
                        if tonumber(value[field]) ~= tonumber(localUserId) then return false, "UserId profile berbeda dari LocalPlayer" end
                        owned = true
                    end
                end
            end
        end
        if owned then return true, "UserId profile cocok LocalPlayer" end
        if replicateAll then return false, "Replion dibagikan ke semua player tanpa pemilik yang cocok" end
        if type(channel) ~= "string" or not table.find(channels or {}, channel) then
            return false, "Channel belum terbukti sebagai profile akun lokal"
        end
        return true, "Channel personal client; UserId tidak diekspos"
    end
    local function insertIndex(index, key, entry)
        if key == nil then return end
        key = tostring(key)
        local previous = index[key]
        if previous and previous.key ~= entry.key then index[key] = false
        elseif previous ~= false then index[key] = entry end
    end
    local catalogVersions = setmetatable({}, {__mode = 'k'})
    function M.catalogVersion(catalog) return catalogVersions[catalog] or 0 end
    function M.touchCatalog(catalog) catalogVersions[catalog] = M.catalogVersion(catalog) + 1 end
    function M.catalog()
        local catalog = { byId = {}, byName = {}, byCategory = {}, namesByCategory = {}, byCollection = {}, count = 0, tiers = {}, variants = {}, mutationNames = {}, enchants = {} }
        -- Names visible in the supplied inventory screenshot; game catalog entries can extend these.
        for _, name in ipairs({"Holographic", "Bloodmoon", "Gemstone", "Fairy Dust", "Radioactive", "Galaxy",
            "Stone", "Moon Fragment", "Midnight", "Frozen", "Ghost", "Sandy", "Albino", "Lightning", "Cupid",
            "Disco", "Corrupt", "Gold", "Festive"}) do catalog.mutationNames[normalized(name)] = name end
        return catalog
    end
    function M.addMutation(catalog, name, id)
        name = clean(name)
        if name == "" then return end
        M.touchCatalog(catalog)
        catalog.mutationNames[normalized(name)] = name
        catalog.variants[name] = name
        if id ~= nil then catalog.variants[tostring(id)] = name end
    end
    function M.addCatalog(catalog, value, fallbackName, fallbackCategory, fallbackId, collection)
        if type(value) ~= "table" then return false end
        local data = type(value.Data) == "table" and value.Data or value
        local name = clean(first(data, nameFields) or first(value, nameFields) or fallbackName)
        local id = first(data, idFields) or first(value, idFields) or fallbackId
        local image = first(data, iconFields) or first(value, iconFields)
        if name == "" or (id == nil and image == nil and data.Type == nil) then return false end
        M.touchCatalog(catalog)
        local category = M.category(data.Type or data.Category or value.Type or value.Category or fallbackCategory)
        local entry = {
            id = id and tostring(id), name = name, category = category,
            icon = M.icon(image), tier = data.Tier or data.Rarity,
            key = category .. "\0" .. tostring(id or name),
            tradeData = tradeData(value),
            tradeRules = type(value.Data) == "table" and type(value.Data.Type) == "string" and {
                itemType = value.Data.Type, isSkin = not not value.IsSkin, hasPrice = not not value.Price,
                tradeLocked = not not value.TradeLocked, hasModifiers = not not value.Modifiers,
            } or nil,
        }
        catalog.byCategory[category] = catalog.byCategory[category] or {}
        local existing = catalog.byCategory[category][entry.id or name]
        if collection then
            catalog.byCollection = catalog.byCollection or {}
            catalog.byCollection[collection] = catalog.byCollection[collection] or {}
            insertIndex(catalog.byCollection[collection], entry.id, existing or entry)
        end
        if existing then
            -- A shared definition may omit the icon that its dedicated catalog provides.
            if existing.name == entry.name then
                if existing.icon == "" and entry.icon ~= "" then existing.icon = entry.icon end
                if existing.tier == nil then existing.tier = entry.tier end
                if entry.tradeRules then existing.tradeRules = entry.tradeRules end
                existing.tradeData = existing.tradeData or {}
                for field, flag in pairs(entry.tradeData) do if existing.tradeData[field] == nil then existing.tradeData[field] = flag end end
            end
            return false
        end
        catalog.byCategory[category][entry.id or name] = entry
        catalog.namesByCategory = catalog.namesByCategory or {}
        catalog.namesByCategory[category] = catalog.namesByCategory[category] or {}
        insertIndex(catalog.namesByCategory[category], normalized(name), entry)
        insertIndex(catalog.byId, entry.id, entry)
        insertIndex(catalog.byName, normalized(name), entry)
        catalog.count = catalog.count + 1
        return true
    end
    function M.ingestCatalog(catalog, value, fallbackName, fallbackCategory, options)
        options = options or {}
        local stats = {added = 0, visited = 0, truncated = false}
        local seen = {}
        local ignoredFields = {metadata = true, meta = true, assets = true, stats = true, statistics = true,
            modifiers = true, mutations = true, enchants = true, enchantments = true, recipes = true,
            ingredients = true, requirements = true, rewards = true, drops = true}
        local walk
        walk = function(node, name, category, keyId, depth)
            if type(node) ~= "table" or seen[node] then return end
            if stats.visited >= (options.MaxNodes or 20000) or depth > 12 then stats.truncated = true; return end
            seen[node] = true; stats.visited = stats.visited + 1
            if options.Checkpoint then options.Checkpoint() elseif options.Yield and stats.visited % 200 == 0 then options.Yield() end
            local data = type(node.Data) == "table" and node.Data or node
            local id = first(data, idFields) or first(node, idFields)
            local title = first(data, nameFields) or first(node, nameFields)
            local image = first(data, iconFields) or first(node, iconFields)
            -- A container can have Name/Icon too; require an actual ID for it to be a descriptor.
            local hasChildren = false
            for key, child in pairs(data) do
                if type(child) == "table" and not ignoredFields[normalized(key)] then hasChildren = true; break end
            end
            local descriptor = id ~= nil or (not hasChildren and (title ~= nil or image ~= nil))
            if descriptor then
                if M.addCatalog(catalog, node, name, category, keyId, options.Collection) then stats.added = stats.added + 1 end
                return -- Metadata/rewards within a definition are not more item definitions.
            end
            local array = #data > 0
            if array then
                local size = 0
                for key in pairs(data) do
                    size = size + 1
                    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #data then array = false; break end
                end
                array = array and size == #data
            end
            for key, child in pairs(data) do
                if type(child) == "table" and not ignoredFields[normalized(key)] then
                    local childCategory = M.catalogCategory(key) or category
                    local numericKey = (type(key) == "number" or type(key) == "string") and tonumber(key)
                    -- Numeric string keys are explicit IDs; sparse numeric maps are IDs too.
                    -- Dense numeric arrays are positions, so never invent IDs from their indexes.
                    local childId = numericKey and (type(key) == "string" or not array) and numericKey or nil
                    local childName = not numericKey and not M.catalogCategory(key) and tostring(key) or nil
                    walk(child, childName, childCategory, childId, depth + 1)
                end
            end
        end
        walk(value, fallbackName, fallbackCategory, nil, 0)
        return stats
    end
    function M.lookup(catalog, id, name, category, collection)
        category = M.category(category)
        if category == "Items" then collection = "Items"; category = "Uncategorized" end
        local scoped = catalog.byCategory[category]
        local registry = collection and catalog.byCollection and catalog.byCollection[collection]
        local byId = id ~= nil and ((scoped and scoped[tostring(id)]) or (registry and registry[tostring(id)]) or catalog.byId[tostring(id)])
        if catalog.definitionScoped and collection == "Items" and byId and category == "Uncategorized" then
            local otherInventory = {Baits=true, ["Fishing Rods"]=true, Boats=true, Abilities=true, Charms=true,
                Emotes=true, Halos=true, Lanterns=true, Pets=true, Potions=true, Totems=true, Booths=true, Finishers=true}
            if otherInventory[byId.category] and not (registry and registry[tostring(id)] == byId) then byId = nil end
        end
        if byId and category ~= "Uncategorized" and byId.category ~= category then byId = nil end
        if byId then return byId end
        local scopedNames = catalog.namesByCategory and catalog.namesByCategory[category]
        local byName = name and ((scopedNames and scopedNames[normalized(name)]) or catalog.byName[normalized(name)])
        if byName and (category == "Uncategorized" or byName.category == category) then
            return byName
        end
        return nil
    end
    -- Session cache contains definitions only, never ownership or stock.
    function M.addDefinitionRequest(result, id, name, category, collection)
        collection = collection or category
        local identifier = id ~= nil and tostring(id) or clean(name)
        if identifier == "" or identifier == "Item UUID" then return end
        local key = tostring(collection) .. "\0" .. tostring(category) .. "\0" .. (id ~= nil and "id:" or "name:") .. identifier
        if result.definitionKeys[key] then return end
        result.definitionKeys[key] = true
        table.insert(result.definitionRequests, {key = key, id = id, name = name, category = category, collection = collection})
    end
    function M.definitionReady(catalog, request)
        local entry = M.lookup(catalog, request.id, request.name, request.category, request.collection)
        if request.collection == "Items" and request.id ~= nil then
            local registry = catalog.byCollection and catalog.byCollection.Items
            entry = registry and registry[tostring(request.id)] or nil
        end
        return entry ~= nil and entry.icon ~= "" and entry.name ~= "" and not entry.name:match("^Item #%d+$")
    end
    function M.acceptDefinition(catalog, request, value)
        if type(value) ~= "table" then return false end
        local data = type(value.Data) == "table" and value.Data or value
        local id = first(data, idFields) or first(value, idFields)
        local name = first(data, nameFields) or first(value, nameFields)
        if request.id ~= nil and (id == nil or tostring(id) ~= tostring(request.id)) then return false end
        if request.id == nil and (not name or normalized(name) ~= normalized(request.name)) then return false end
        local category = M.category(data.Type or data.Category or value.Type or value.Category or request.category)
        local expected = M.category(request.category)
        if expected ~= "Items" and expected ~= "Uncategorized" and expected ~= category then return false end
        M.addCatalog(catalog, value, request.name, request.category, request.id, request.collection)
        return M.definitionReady(catalog, request)
    end

    function M.unmappedCatalogRows(rows)
        local groups, lines = {}, {}
        for _, row in ipairs(rows or {}) do
            if not row.resolved or row.icon == "" then
                local group = groups[row.category] or {count = 0, samples = {}}
                groups[row.category] = group; group.count = group.count + 1
                if #group.samples < 4 then
                    table.insert(group.samples, "ID=" .. (row.id ~= "" and row.id or "tanpa ID")
                        .. " nama=" .. row.name .. (row.resolved and " (ikon belum ditemukan)" or " (definisi belum ditemukan)"))
                end
            end
        end
        for category, group in pairs(groups) do
            table.insert(lines, category .. " [" .. group.count .. "]: " .. table.concat(group.samples, "; "))
        end
        table.sort(lines)
        return #lines > 0 and table.concat(lines, "\n") or "Tidak ada"
    end
    function M.path(root, path)
        local cursor = root
        for _, part in ipairs(path) do
            if type(cursor) ~= "table" then return nil end
            cursor = cursor[part]
        end
        return cursor
    end
    function M.inventory(data, paths)
        for _, path in ipairs(paths) do
            local value = M.path(data, path)
            if type(value) == "table" then return value, table.concat(path, ".") end
        end
        return nil
    end
    local function metadata(record)
        return type(record.Metadata) == "table" and record.Metadata
            or type(record.Meta) == "table" and record.Meta or {}
    end
    function M.tradeEligibility(record, entry)
        record = record or {}
        local facts = type(record.TradeData) == "table" and record.TradeData or tradeData(record)
        local allowed, blocked, rap, proof
        for index, source in ipairs({facts, entry and entry.tradeData or {}}) do
            for fieldIndex, field in ipairs(tradeFields) do
                local value = source[field]
                local origin = (index == 1 and "record." or "catalog.") .. field
                if fieldIndex <= 5 and type(value) == "boolean" then
                    if value then allowed = origin else blocked = origin end
                elseif type(value) == "number" and value == value and value > 0 and value < math.huge then
                    if field == "RAP" or field == "Rap" or field == "rap" or field == "RecentAveragePrice" then rap = value; proof = origin end
                end
            end
        end
        local rules = entry and entry.tradeRules
        if rules then
            local supported = {Fish=true, ["Fishing Rods"]=true, Boats=true, Baits=true, Charms=true,
                Emotes=true, Halos=true, Lanterns=true, ["Enchant Stones"]=true, Pets=true, ["Pet Eggs"]=true, Gears=true, Potions=true}
            local skinOnly = rules.itemType == "Baits" or rules.itemType == "Fishing Rods"
            local excludesCoins = skinOnly or rules.itemType == "Charms" or rules.itemType == "Boats"
                or rules.itemType == "Lanterns" or rules.itemType == "Emotes"
            local meta = metadata(record)
            local cargo = record.PetCargo
            local permitsModifiers = rules.itemType == "Potions" or rules.itemType == "Pets" or rules.itemType == "Charms"
            local valid = supported[rules.itemType] and (not skinOnly or rules.isSkin) and (not excludesCoins or not rules.hasPrice)
                and not rules.tradeLocked and not meta.TradeLock and not (type(cargo) == "table" and #cargo > 0)
                and (permitsModifiers or not rules.hasModifiers)
            return {status = valid and "tradable" or "notTradable", rap = rap, source = "TradeData.FollowTradeRules (source)"}
        end
        if blocked then return {status = "notTradable", rap = rap, source = blocked} end
        if allowed then return {status = "tradable", rap = rap, source = allowed} end
        return {status = "unknown", rap = rap, source = rap and "RAP tersedia; aturan trade belum terbaca" or "Aturan trade belum tersedia"}
    end
    function M.tradeRAP(data, itemType, id)
        local raps = type(data) == "table" and data.RAPs
        local category = type(raps) == "table" and raps[itemType]
        local value = type(category) == "table" and category[itemType .. "/" .. tostring(id)]
        if type(value) == "number" and value == value and value >= 0 and value < math.huge then return value end
        return nil
    end
    local function copyMutationValue(value)
        local remaining,active=128,{}
        local function copy(child,depth)
            if type(child)~="table" then
                local kind=type(child)
                if kind=="number" and (child~=child or math.abs(child)==math.huge) then error("Angka mutasi tidak valid",0) end
                if kind=="string" or kind=="number" or kind=="boolean" or kind=="nil" then return child end
                error("Tipe field mutasi tidak didukung: " .. kind,0)
            end
            if active[child] then error("Referensi mutasi melingkar",0) end
            if depth>8 then error("Field mutasi terlalu dalam",0) end
            active[child]=true
            local out={}
            for key,item in pairs(child) do
                remaining-=1; if remaining<0 then error("Field mutasi melebihi batas salinan",0) end
                if type(key)~="string" and type(key)~="number" then error("Key field mutasi tidak didukung",0) end
                out[key]=copy(item,depth+1)
            end
            active[child]=nil; return out
        end
        local ok,copied=pcall(copy,value,0)
        if ok then return copied end
        return nil,tostring(copied)
    end
    function M.itemVariants(record, catalog, displayName)
        local parts, seen, traits, evidence, issues, unmapped = {}, {}, {}, {}, {}, {}
        local present, explicitNone, visited = false, false, 0
        local function issue(text) if #issues < 8 then table.insert(issues, text) end end
        local function add(part)
            if part == false then explicitNone = true; return end
            if type(part) ~= "string" and type(part) ~= "number" then issue("Nilai mutasi bukan nama/ID: " .. type(part)); return end
            if type(part)=="number" and (part~=part or math.abs(part)==math.huge) then issue("ID mutasi bukan angka finite"); return end
            local text = clean(part)
            if text == "" or text:lower() == "none" or text:lower() == "normal" or text == "0" then explicitNone = true; return end
            local mapped = catalog.variants and catalog.variants[text] or (catalog.mutationNames and catalog.mutationNames[normalized(text)])
            if mapped then text = mapped
            elseif tonumber(text) then
                unmapped[text] = true; text = "Mutasi #" .. text
            end
            for _, flag in ipairs({"Shiny", "Big", "Mega"}) do
                if normalized(text) == normalized(flag) then traits[flag] = true; return end
            end
            if not seen[text] then seen[text] = true; table.insert(parts, text) end
        end
        local read
        read = function(value, depth, active)
            visited = visited + 1
            if visited > 128 or depth > 4 then issue("Batas pembacaan field mutasi tercapai"); return end
            if type(value) == "table" then
                if active[value] then issue("Field mutasi memiliki referensi melingkar"); return end
                active[value] = true
                local descriptor = first(value, {"Name", "Id", "MutationId", "VariantId"})
                if descriptor ~= nil then read(descriptor, depth + 1, active)
                elseif next(value) == nil then explicitNone = true
                else
                    for key, part in pairs(value) do
                        if visited >= 128 then issue("Batas pembacaan field mutasi tercapai"); break end
                        if part == true then add(key) else read(part, depth + 1, active) end
                    end
                end
                active[value] = nil
            else add(value) end
        end
        local sources = {{data=record,path="record"}}
        local function source(value,path) if type(value)=="table" then table.insert(sources,{data=value,path=path}) end end
        source(record.Metadata,"Metadata"); source(record.Meta,"Meta")
        if type(record.Data) == "table" then
            source(record.Data,"Data"); source(record.Data.Metadata,"Data.Metadata"); source(record.Data.Meta,"Data.Meta")
        end
        local function consume(value,path)
            present = true; read(value,0,{})
            if #evidence < 64 then
                local copied,err = copyMutationValue(value)
                if err then issue(err) end
                table.insert(evidence,{path=path,value=copied,error=err and tostring(err) or nil})
            end
        end
        -- Preserve raw field provenance through normalized bag records. Numeric IDs must be
        -- remapped when the mutation catalog arrives, rather than becoming permanent labels.
        if type(record.MutationEvidence)=="table" then
            for index,entry in ipairs(record.MutationEvidence) do
                if index>64 then issue("Bukti field mutasi terpotong"); break end
                if type(entry)=="table" and type(entry.path)=="string" then
                    if entry.error then present=true; issue(entry.error); table.insert(evidence,{path=entry.path,error=entry.error})
                    else consume(entry.value,entry.path) end
                end
            end
        else
            for _, entry in ipairs(sources) do
                for _, field in ipairs(mutationFields) do
                    if entry.data[field]~=nil then consume(entry.data[field],entry.path .. "." .. field) end
                end
            end
        end
        if type(displayName) == "string" then source({Name=displayName},"displayName") end
        for _, entry in ipairs(sources) do
            local value = entry.data
            for _, flag in ipairs({"Shiny", "Big", "Mega"}) do if value[flag] == true then traits[flag] = true end end
            local name = first(value, nameFields)
            if type(name) == "string" then
                for token in name:gmatch("%S+") do
                    if token == "Shiny" or token == "Big" or token == "Mega" then traits[token] = true else break end
                end
            end
        end
        table.sort(parts)
        local combined = table.clone(parts)
        for _, flag in ipairs({ "Shiny", "Big", "Mega" }) do
            if traits[flag] then table.insert(combined, flag) end
        end
        table.sort(combined)
        local status = next(unmapped) and "unmapped" or (#issues>0 and "invalid") or (#parts>0 and "known")
            or ((present and (explicitNone or next(traits))) and "none") or "unknown"
        local reason = status=="unknown" and "Field mutasi belum tersedia; ketiadaan field tidak membuktikan Normal."
            or status=="none" and "Field mutasi eksplisit kosong/Normal atau hanya berisi trait."
            or status=="unmapped" and "ID mutasi tersedia tetapi nama belum ada pada katalog."
            or status=="invalid" and table.concat(issues,"; ") or "Nama mutasi terbaca dari field item."
        return {mutation = table.concat(parts, " + "), mutations = parts, traits = traits, variant = table.concat(combined, " + "),
            status=status,reason=reason,evidence=evidence,issues=issues,unmappedIds=unmapped}
    end
    function M.mutationDisplay(row)
        local text = row.mutation or ""
        if row.mutationStatus=="unmapped" then return text .. " (nama belum dipetakan)" end
        if row.mutationStatus=="invalid" then return (text~="" and text .. " | " or "") .. "Data belum terbaca lengkap" end
        if text~="" then return text end
        return row.mutationStatus=="none" and "Normal" or "Belum terbaca"
    end
    local function mutationPreview(value, depth, active)
        if type(value)~="table" then return tostring(value):gsub("[%c]"," "):sub(1,150) end
        if depth>=2 or active[value] then return "{...}" end
        active[value]=true
        local parts={}
        for key,child in pairs(value) do
            if #parts>=6 then table.insert(parts,"..."); break end
            table.insert(parts,tostring(key):sub(1,40) .. "=" .. mutationPreview(child,depth+1,active))
        end
        active[value]=nil; table.sort(parts)
        return "{" .. table.concat(parts,", ") .. "}"
    end
    function M.mutationDiagnostics(snapshot)
        local data=snapshot and snapshot.mutationDiagnostics
        if not data then return "Mutasi item: belum diperiksa" end
        local lines={"Mutasi Fish/Gears/Items: " .. data.total .. " record; terbaca=" .. data.known .. "; normal eksplisit=" .. data.none
            .. "; ID belum dipetakan=" .. data.unmapped .. "; belum tersedia=" .. data.unknown .. "; format gagal=" .. data.invalid,
            "Field yang diperiksa: record/Metadata/Meta/Data; VariantId/VariantIds, MutationId/MutationIds, Variant, Mutation, Mutations.",
            "Contoh field mutasi item (maksimal 3 per status):"}
        for _, sample in ipairs(data.samples) do
            table.insert(lines,sample.category .. " | " .. sample.name .. " | ID=" .. sample.id .. " | UUID=" .. sample.uuid
                .. " | " .. sample.status .. " | " .. sample.reason)
            for _, evidence in ipairs(sample.evidence) do
                table.insert(lines,"  " .. evidence.path .. "=" .. (evidence.error and ("Gagal menyalin: " .. evidence.error) or mutationPreview(evidence.value,0,{})))
            end
            if #sample.evidence==0 then table.insert(lines,"  Field mutasi yang didukung: tidak ditemukan") end
            if sample.metadataKeys~="" then table.insert(lines,"  Field metadata tersedia: " .. sample.metadataKeys) end
            for _, hint in ipairs(sample.hints) do table.insert(lines,"  Field terkait belum dibaca: " .. hint) end
        end
        if snapshot.truncated then table.insert(lines,"Pembacaan inventory terpotong; ringkasan mutasi hanya mencakup record yang sempat dibaca.") end
        return table.concat(lines,"\n")
    end
    function M.displayItemName(row)
        local prefix = {}
        for _, flag in ipairs({"Mega", "Big", "Shiny"}) do
            if row.traits and row.traits[flag] and not (" " .. row.name .. " "):find(" " .. flag .. " ", 1, true) then table.insert(prefix, flag) end
        end
        return (#prefix > 0 and table.concat(prefix, " ") .. " " or "") .. row.name
    end
    local wrappers = { items = true, inventory = true, data = true, contents = true, entries = true }
    local ignored = {
        metadata = true, meta = true, equipped = true, equippeditems = true, equippedrods = true,
        equippedbait = true, capacity = true, maxcapacity = true, version = true,
        equippedrod = true, equippedfishingrod = true, equippedabilities = true, equippedability = true,
        equippedrodid = true, equippedroduuid = true, equippedbaitid = true, equippedabilityid = true,
        equippedpet = true, equippedpetid = true, equippedpetuuid = true,
        equippedpotions = true, equippedpotionuuid = true, equippedpotionid = true,
        selected = true, selecteditem = true, lastupdated = true,
    }
    local function isArray(value)
        local length, count = #value, 0
        if length == 0 then return false end
        for key in pairs(value) do
            if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then return false end
            count = count + 1
        end
        return count == length
    end
    local function itemRecord(value)
        return type(value) == "table" and (first(value, idFields) ~= nil or first(value, nameFields) ~= nil
            or first(value, qtyFields) ~= nil or first(value, uniqueFields) ~= nil)
    end
    -- One checkpoint can be shared by all stages of a completed read.
    function M.workCheckpoint(yieldFn, clock, budget)
        local last = clock()
        return function()
            if clock() - last >= (budget or 0.002) then yieldFn(); last = clock() end
        end
    end
    function M.normalize(inventory, catalog, options)
        options = options or {}
        local result = { rows = {}, total = 0, unresolved = 0, missingIcons = 0, visited = 0, skipped = 0, truncated = false,
            mutationDiagnostics={total=0,known=0,none=0,unmapped=0,unknown=0,invalid=0,samples={}} }
        local mutationSamples={}
        if options.CollectRecords then result.items = {} end
        if options.CollectDefinitions then result.definitionRequests = {}; result.definitionKeys = {} end
        local groups, seenTables, seenInstances = {}, {}, {}
        local limit = options.MaxNodes or 200000
        local function rawEmit(record, key, category, path, scalarQty, collection)
            if type(record.Data) == "table" then
                local merged = table.clone(record)
                for field, value in pairs(record.Data) do if merged[field] == nil then merged[field] = value end end
                record = merged
            end
            local id = first(record, idFields)
            local name = first(record, nameFields)
            local uid = first(record, uniqueFields) or M.uuid(key)
            uid = M.uuid(uid) or uid
            if options.UUIDs and (uid == nil or not options.UUIDs[tostring(uid)]) then return end
            if id == nil and name == nil and type(key) == "string" and not M.uuid(key) then
                if key:match("^%d+$") then id = key else name = key end
            end
            if id == nil and name == nil and not uid then result.skipped = result.skipped + 1; return end
            category = M.category(record.Type or record.Category or category)
            local definitionCategory = category
            local entry = M.lookup(catalog, id, name, category, collection)
            category = M.category((entry and entry.category) or record.Type or record.Category or category)
            if entry and (name == "Item UUID" or (id ~= nil and name == "Item #" .. tostring(id))) then name = nil end
            name = clean(name or (entry and entry.name) or (id and "Item #" .. tostring(id)) or (uid and "Item UUID") or key)
            local rawQty = scalarQty
            if rawQty == nil then rawQty = first(record, qtyFields) end
            local qty = rawQty == nil and 1 or tonumber(rawQty)
            if not qty or qty ~= qty or qty == math.huge or qty <= 0 then result.skipped = result.skipped + 1; return end
            if uid then
                local uniqueKey = tostring(uid)
                if seenInstances[uniqueKey] then return end
                seenInstances[uniqueKey] = true
            end
            if result.definitionRequests then
                M.addDefinitionRequest(result, id, name, definitionCategory, collection)
            end
            local variants = M.itemVariants(record, catalog, name)
            local mutation = variants.variant
            local meta = metadata(record)
            if category=="Fish" or category=="Gears" or category=="Items" or category=="Uncategorized" then
                local diagnostic=result.mutationDiagnostics
                diagnostic.total+=1; diagnostic[variants.status]+=1
                if (mutationSamples[variants.status] or 0)<3 then
                    mutationSamples[variants.status]=(mutationSamples[variants.status] or 0)+1
                    local keys,hints={},{}
                    local supported={}; for _, field in ipairs(mutationFields) do supported[field]=true end
                    local function inspect(value,origin,metadataKeys)
                        if type(value)~="table" then return end
                        local fields,checked={},0
                        for field,child in pairs(value) do
                            checked+=1; if checked>64 then table.insert(fields,"..."); break end
                            if #fields<16 then table.insert(fields,tostring(field):sub(1,60)) end
                            local lower=tostring(field):lower()
                            if not supported[field] and field~="MutationEvidence" and field~="MutationStatus"
                                and (lower:find("mutation",1,true) or lower:find("variant",1,true)) and #hints<8 then
                                table.insert(hints,origin .. "." .. tostring(field) .. "=" .. mutationPreview(child,0,{}))
                            end
                        end
                        if metadataKeys then table.sort(fields); table.insert(keys,origin .. ": " .. table.concat(fields,", ")) end
                    end
                    inspect(record,"record",false); inspect(record.Metadata,"Metadata",true); inspect(record.Meta,"Meta",true)
                    if type(record.Data)=="table" then
                        inspect(record.Data,"Data",false); inspect(record.Data.Metadata,"Data.Metadata",true); inspect(record.Data.Meta,"Data.Meta",true)
                    end
                    table.insert(diagnostic.samples,{category=category,name=name,id=tostring(id or ""),uuid=tostring(uid or "Belum tersedia"),
                        status=variants.status,reason=variants.reason,evidence=variants.evidence,metadataKeys=table.concat(keys," | "),hints=hints})
                end
            end
            local rarity = record.Rarity or record.rarity or record.Tier or (entry and entry.tier)
            rarity = rarity ~= nil and (catalog.tiers[tostring(rarity)] or (type(rarity) == "number" and "Tier " .. tostring(rarity)) or tostring(rarity)) or "Unknown"
            local icon = M.icon(first(record, iconFields))
            if icon == "" and entry then icon = entry.icon end
            local groupKey = category .. "\0" .. tostring((entry and entry.id) or id or (name == "Item UUID" and uid) or name)
                .. "\0" .. name .. "\0" .. mutation .. "\0" .. rarity .. "\0" .. variants.status
            local row = groups[groupKey]
            if not row then
                row = {
                    key = groupKey, id = tostring((entry and entry.id) or id or ""), name = name,
                    category = category, variant = mutation, mutation = variants.mutation, mutations = variants.mutations,
                    traits = variants.traits, mutationStatus = variants.status, mutationReason = variants.reason, rarity = rarity, icon = icon,
                    qty = 0, records = 0, favoriteQty = 0, lockedQty = 0, instances = {}, paths = {}, resolved = entry ~= nil,
                }
                groups[groupKey] = row
                table.insert(result.rows, row)
            end
            if row.icon == "" then row.icon = icon end
            row.qty = row.qty + qty
            row.records = row.records + 1
            result.total = result.total + qty
            if record.Favorite == true or record.Favorited == true or meta.Favorite == true or meta.Favorited == true then
                row.favoriteQty = row.favoriteQty + qty
            end
            if record.Locked == true or record.TradeLocked == true or meta.Locked == true or meta.TradeLocked == true then
                row.lockedQty = row.lockedQty + qty
            end
            local weight = tonumber(record.Weight or record.Kg or meta.Weight or meta.Kg)
            if weight and weight == weight and weight >= 0 and weight < math.huge then
                row.minWeight = math.min(row.minWeight or weight, weight)
                row.maxWeight = math.max(row.maxWeight or weight, weight)
            end
            if uid then table.insert(row.instances, tostring(uid)) end
            if result.items then
                local copiedMeta = M.copyData(meta, nil, options.Checkpoint) or {}
                for _, flag in ipairs({"Big", "Shiny", "Mega"}) do if record[flag] == true then copiedMeta[flag] = true end end
                table.insert(result.items, {Id = (entry and entry.id) or id, Name = name, Type = category, UUID = uid,
                    Quantity = qty, Icon = icon, Rarity = rarity, Metadata = copiedMeta, GroupKey = groupKey,
                    Mutation = #variants.mutations == 1 and variants.mutations[1] or nil, Mutations = table.clone(variants.mutations),
                    MutationEvidence = variants.evidence, MutationStatus = variants.status,
                    Shiny = variants.traits.Shiny, Big = variants.traits.Big, Mega = variants.traits.Mega,
                    Weight = weight, Favorited = record.Favorited, Reader = record.Reader,
                    Locked = record.Locked, TradeLocked = record.TradeLocked, TradeLock = M.copyData(record.TradeLock, 128),
                    TradeData = tradeData(record),
                    PetCargo = M.copyData(record.PetCargo, 128),
                    GuiPath = record.GuiPath,
                    Enchantments = first(record, {"Enchantments", "Enchants", "Enchantment", "Enchant", "EnchantId", "EnchantmentId"}),
                    SecondEnchantments = first(record, secondaryEnchantFields)})
            end
            if #row.paths < 5 then table.insert(row.paths, path) end
        end
        -- Only collector-owned immutable records may use this cache. Live trade reads
        -- deliberately keep the uncached path. Replace both indexes after each read
        -- so removed records and superseded versions cannot accumulate.
        local memo = options.ImmutableCache
        if memo and (memo.catalog ~= catalog or memo.version ~= M.catalogVersion(catalog)
            or memo.collectRecords ~= options.CollectRecords or memo.collectDefinitions ~= options.CollectDefinitions) then
            table.clear(memo); memo.catalog = catalog; memo.version = M.catalogVersion(catalog)
            memo.collectRecords = options.CollectRecords; memo.collectDefinitions = options.CollectDefinitions
            memo.records = {}
            memo.byUUID = {}
        end
        local nextUUID = memo and {} or nil
        local nextRecords = memo and {} or nil
        local function emit(record, key, category, path, scalarQty, collection)
            if not memo or scalarQty ~= nil or options.UUIDs then rawEmit(record, key, category, path, scalarQty, collection); return end
            local uid = M.uuid(first(record,uniqueFields) or (type(record.Data)=="table" and first(record.Data,uniqueFields)) or key)
            local cacheKey = key
            if uid and (first(record,idFields) or first(record,nameFields)
                or type(record.Data)=="table" and (first(record.Data,idFields) or first(record.Data,nameFields))) then cacheKey = uid end
            local cached = nextRecords[record] or memo.records[record] or (uid and memo.byUUID[uid])
            local reusable = cached and cached.key == cacheKey and cached.category == category and cached.collection == collection
                and M.dataEqual(cached.input,record,options.Checkpoint)
            if not reusable then
                local outer, outerGroups, outerSeen, outerSamples = result, groups, seenInstances, mutationSamples
                result = {rows = {}, items = options.CollectRecords and {} or nil, total = 0, skipped = 0,
                    definitionRequests = options.CollectDefinitions and {} or nil, definitionKeys = {},
                    mutationDiagnostics = {total=0,known=0,none=0,unmapped=0,unknown=0,invalid=0,samples={}}}
                groups, seenInstances, mutationSamples = {}, {}, {}
                rawEmit(record, key, category, path, scalarQty, collection)
                cached = {key=cacheKey,category=category,collection=collection,value=result,input=record}
                result, groups, seenInstances, mutationSamples = outer, outerGroups, outerSeen, outerSamples
                memo.misses = (memo.misses or 0) + 1
            else memo.hits = (memo.hits or 0) + 1 end
            nextRecords[record] = cached
            if uid and not nextUUID[uid] then nextUUID[uid] = cached end
            local part = cached.value
            local row = part.rows[1]
            local rowUUID = row and row.instances[1]
            if rowUUID and seenInstances[rowUUID] then return end
            if rowUUID then seenInstances[rowUUID] = true end
            result.total += part.total; result.skipped += part.skipped
            for field, count in pairs(part.mutationDiagnostics) do
                if field ~= "samples" then result.mutationDiagnostics[field] += count end
            end
            for _, sample in ipairs(part.mutationDiagnostics.samples) do
                if (mutationSamples[sample.status] or 0) < 3 then
                    mutationSamples[sample.status] = (mutationSamples[sample.status] or 0) + 1
                    table.insert(result.mutationDiagnostics.samples, sample)
                end
            end
            for _, request in ipairs(part.definitionRequests or {}) do
                if not result.definitionKeys[request.key] then
                    result.definitionKeys[request.key] = true; table.insert(result.definitionRequests, request)
                end
            end
            if result.items then for _, item in ipairs(part.items) do table.insert(result.items, item) end end
            if not row then return end
            local target = groups[row.key]
            if not target then
                target = table.clone(row); target.instances = table.clone(row.instances); target.paths = {path}
                groups[row.key] = target; table.insert(result.rows, target)
            else
                for _, field in ipairs({"qty","records","favoriteQty","lockedQty"}) do target[field] += row[field] end
                if target.icon == "" then target.icon = row.icon end
                if row.minWeight then target.minWeight = math.min(target.minWeight or row.minWeight, row.minWeight) end
                if row.maxWeight then target.maxWeight = math.max(target.maxWeight or row.maxWeight, row.maxWeight) end
                if rowUUID then table.insert(target.instances, rowUUID) end
                if #target.paths < 5 then table.insert(target.paths, path) end
            end
        end
        local walk
        walk = function(value, category, path, depth, key, collection)
            result.visited = result.visited + 1
            if result.visited > limit or depth > 12 then result.truncated = true; return end
            if options.Checkpoint then options.Checkpoint() elseif options.Yield and result.visited % 400 == 0 then options.Yield() end
            if type(value) ~= "table" or seenTables[value] then return end
            seenTables[value] = true
            if itemRecord(value) or M.uuid(key) or (type(value.Data) == "table" and itemRecord(value.Data)) then
                emit(value, key, category, path, nil, collection); return
            end
            local array = isArray(value)
            for childKey, child in pairs(value) do
                if result.visited >= limit then result.truncated = true; break end
                local keyText, childCategory = tostring(childKey), category
                local normalizedKey = normalized(keyText)
                local childCollection = normalizedKey == "items" and "Items" or (M.catalogCategory(keyText) and keyText) or collection
                local childPath = path .. "." .. keyText
                if not ignored[normalizedKey] then
                    if type(child) == "table" then
                        if type(childKey) == "string" and not itemRecord(child) and not wrappers[normalizedKey]
                            and not childKey:match("^%d+$") and not M.uuid(childKey) then
                            childCategory = M.category(keyText)
                        end
                        walk(child, childCategory, childPath, depth + 1, childKey, childCollection)
                    elseif type(child) == "number" or type(child) == "string" or child == true then
                        result.visited = result.visited + 1
                        if options.Checkpoint then options.Checkpoint() elseif options.Yield and result.visited % 400 == 0 then options.Yield() end
                        if array and (type(child) == "number" or type(child) == "string") then
                            if type(child) == "number" or tostring(child):match("^%d+$") then
                                emit({ Id = child }, childKey, childCategory, childPath, nil, childCollection)
                            else emit({ Name = child }, childKey, childCategory, childPath, nil, childCollection) end
                        elseif child == true then
                            emit({}, keyText, childCategory, childPath, 1, childCollection)
                        elseif tonumber(child) then
                            emit({}, keyText, childCategory, childPath, tonumber(child), childCollection)
                        else result.skipped = result.skipped + 1 end
                    end
                end
            end
        end
        walk(inventory, options.Category or "Uncategorized", options.Path or "Inventory", 0, nil, options.Collection)
        if memo then memo.byUUID = nextUUID; memo.records = nextRecords end
        for _, row in ipairs(result.rows) do
            if not row.resolved then result.unresolved = result.unresolved + 1 end
            if row.icon == "" then result.missingIcons = result.missingIcons + 1 end
        end
        table.sort(result.rows, function(a, b)
            if a.category ~= b.category then return a.category < b.category end
            if a.name ~= b.name then return a.name:lower() < b.name:lower() end
            return a.key < b.key
        end)
        return result
    end
    function M.diff(before, after)
        local changes, old, current = {}, {}, {}
        for _, row in ipairs(before or {}) do old[row.key] = row end
        for _, row in ipairs(after or {}) do
            current[row.key] = true
            local delta = row.qty - (old[row.key] and old[row.key].qty or 0)
            if delta ~= 0 then table.insert(changes, { name = row.name, category = row.category, variant = row.variant, delta = delta }) end
        end
        for _, row in ipairs(before or {}) do
            if not current[row.key] then table.insert(changes, { name = row.name, category = row.category, variant = row.variant, delta = -row.qty }) end
        end
        table.sort(changes, function(a, b) return a.name < b.name end)
        return changes
    end
    function M.filter(rows, category, query, order)
        local filtered = {}
        query = clean(query):lower()
        for _, row in ipairs(rows) do
            local text = (row.name .. " " .. row.id .. " " .. row.category .. " " .. row.variant .. " " .. row.rarity
                .. " " .. table.concat(row.instances or {}, " ")):lower()
            if (category == "Semua" or category == row.category) and (query == "" or text:find(query, 1, true)) then
                table.insert(filtered, row)
            end
        end
        table.sort(filtered, function(a, b)
            if order == "Jumlah" and a.qty ~= b.qty then return a.qty > b.qty end
            if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
            return a.key < b.key
        end)
        return filtered
    end
    -- A passive copy of only the inventory protocol. Never writes to the game's Replion.
    function M.copyData(value, limit, checkpoint)
        local remaining, seen = limit or 200000, {}
        local function copy(child, depth)
            if type(child) ~= "table" then
                if type(child) == "string" or type(child) == "number" or type(child) == "boolean" then return child end
                return nil
            end
            if seen[child] then return seen[child] end
            if depth > 24 then error("Inventory payload terlalu dalam") end
            local result = {}; seen[child] = result
            for key, item in next, child do
                if checkpoint then checkpoint() end
                remaining = remaining - 1
                if remaining < 0 then error("Inventory payload melebihi batas salinan") end
                if type(key) == "string" or type(key) == "number" then result[key] = copy(item, depth + 1) end
            end
            return result
        end
        local ok, result = pcall(copy, value, 0)
        if ok then return result end
        return nil, result
    end
    local function protocolPath(value)
        local parts = {}
        if type(value) == "string" then
            for key in value:gmatch("[^%.]+") do table.insert(parts, tonumber(key) or key) end
        elseif type(value) == "table" then
            for index = 1, #value do
                local key = value[index]
                if type(key) ~= "string" and type(key) ~= "number" then return nil end
                table.insert(parts, key)
            end
        else return nil end
        if #parts > 24 then return nil end
        if parts[1] == "Data" or parts[1] == "Profile" then table.remove(parts, 1) end
        if parts[1] ~= "Inventory" then return nil end
        return parts
    end
    local function pathName(parts)
        local names = {}; for _, part in ipairs(parts) do table.insert(names, tostring(part)) end
        return table.concat(names, ".")
    end
    local function setPath(root, path, value)
        local cursor = root
        for index = 1, #path - 1 do
            local key = path[index]
            if type(cursor[key]) ~= "table" then cursor[key] = {} end
            cursor = cursor[key]
        end
        cursor[path[#path]] = value
    end
    function M.eventStore()
        return { records = {}, excludedIds = {}, sequence = 0, accepted = 0, ignored = 0, rejected = 0 }
    end
    function M.observe(store, remote, args, options)
        options = options or {}
        local limit = options.MaxNodes or 200000
        local function reject(message)
            store.rejected = store.rejected + 1; store.lastError = message
            return false
        end
        local function accept(record, label)
            store.sequence = store.sequence + 1; store.accepted = store.accepted + 1
            record.sequence = store.sequence; record.capturedAt = os.time(); store.lastPath = label
            return true
        end
        if remote == "Removed" then
            local record = store.records[args[1]]
            if record then store.records[args[1]] = nil; return accept(record, "Removed") end
            return false
        end
        if remote == "Added" then
            local batch = type(args[1]) == "table" and (type(args[1][1]) == "table" and args[1] or { args[1] }) or {}
            local found = false
            for _, serialized in ipairs(batch) do
                local owns, scopeReason = true, nil
                if options.LocalUserId then
                    owns, scopeReason = M.profileScope(serialized[3], options.LocalUserId, serialized[2],
                        serialized[4] == "All", options.PersonalChannels)
                end
                local inventory = type(serialized[3]) == "table" and M.inventory(serialized[3],
                    { { "Inventory" }, { "Data", "Inventory" }, { "Profile", "Inventory" } })
                if not owns and serialized[1] ~= nil then
                    store.excludedIds[serialized[1]] = true; store.records[serialized[1]] = nil
                    if inventory then reject(scopeReason) end
                elseif type(inventory) == "table" and serialized[1] ~= nil then
                    store.excludedIds[serialized[1]] = nil
                    local value, err = M.copyData(inventory, limit)
                    if err then reject(err)
                    else
                        local record = { id = serialized[1], channel = serialized[2], data = { Inventory = value }, complete = true, completePaths = {} }
                        store.records[serialized[1]] = record; accept(record, "Added.Inventory"); found = true
                    end
                end
            end
            return found
        end
        local path = protocolPath(remote == "ArrayUpdate" and args[3] or args[2])
        -- Root Update can carry an entire inventory in its dictionary.
        local rootUpdate = remote == "Update" and args[3] == nil and type(args[2]) == "table" and args[2].Inventory
        if not path and (type(rootUpdate) == "table" or rootUpdate == "\0") then path = { "Inventory" } end
        if not path or args[1] == nil then store.ignored = store.ignored + 1; return false end
        if store.excludedIds[args[1]] then store.ignored = store.ignored + 1; return false end
        if remote ~= "Set" and remote ~= "Update" and remote ~= "ArrayUpdate" then return false end
        local id, label = args[1], pathName(path)
        local record = store.records[id]
        if not record then
            if options.MaxChannels and options.MaxChannels <= 0 then return reject("Channel limit") end
            local count = 0; for _ in pairs(store.records) do count = count + 1 end
            if count >= (options.MaxChannels or 16) then return reject("Terlalu banyak channel inventori") end
            record = { id = id, data = { Inventory = {} }, complete = false, completePaths = {} }
        end
        if remote == "Set" or rootUpdate then
            local value, err = M.copyData(rootUpdate or args[3], limit)
            if err then return reject(err) end
            if value == "\0" then value = nil end
            setPath(record.data, path, value)
            -- Replacing an ancestor invalidates assumptions about its previous descendants.
            for known in pairs(record.completePaths) do
                if known == label or known:sub(1, #label + 1) == label .. "." then record.completePaths[known] = nil end
            end
            if type(value) == "table" then
                record.completePaths[label] = true
                if #path == 1 then record.complete = true end
            elseif #path == 1 then record.complete = false end
        elseif remote == "Update" then
            if type(args[3]) ~= "table" then return reject("Update inventory tanpa dictionary") end
            local value, err = M.copyData(args[3], limit)
            if err then return reject(err) end
            local target = M.path(record.data, path)
            if type(target) ~= "table" then target = {}; setPath(record.data, path, target) end
            for key, child in pairs(value) do
                local targetKey = args[4] and (tonumber(key) or key) or key
                if child == "\0" then target[targetKey] = nil else target[targetKey] = child end
            end
        else
            local action = args[2]
            if action ~= "i" and action ~= "r" and action ~= "c" then return reject("ArrayUpdate action tidak dikenali") end
            local array = M.path(record.data, path)
            if type(array) ~= "table" then array = {}; setPath(record.data, path, array) end
            local trusted = record.complete or record.completePaths[label] == true
            if action == "c" then
                setPath(record.data, path, {}); record.completePaths[label] = true
            elseif action == "i" then
                local value, err = M.copyData(args[4], limit)
                if err then return reject(err) end
                store.lastItem = type(value) == "table" and value or nil
                local index = args[5]
                if index ~= nil and (type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > limit) then
                    return reject("Index insert tidak valid")
                end
                if trusted then
                    index = index or #array + 1
                    if index > #array + 1 then return reject("Index insert di luar snapshot") end
                    table.insert(array, index, value)
                elseif index then
                    local slots = {}; for key in pairs(array) do if type(key) == "number" and key >= index then table.insert(slots, key) end end
                    table.sort(slots, function(a, b) return a > b end)
                    for _, key in ipairs(slots) do array[key + 1] = array[key]; array[key] = nil end
                    array[index] = value
                else
                    -- The server did not send an index. Keep a UUID record without inventing its absolute slot.
                    local uid = type(value) == "table" and first(value, uniqueFields)
                    array[M.uuid(uid) or uid or ("observed:" .. tostring(store.sequence + 1))] = value
                end
            else
                local index = args[4]
                if index ~= nil and (type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > limit) then
                    return reject("Index remove tidak valid")
                end
                if trusted then
                    index = index or #array
                    if index >= 1 and index <= #array then table.remove(array, index) end
                else
                    local unindexed = false; for key in pairs(array) do if type(key) ~= "number" then unindexed = true; break end end
                    if not index or unindexed then
                        setPath(record.data, path, {})
                        record.warning = "Remove tanpa posisi yang dapat dipastikan: cache parsial dikosongkan."
                    else
                        array[index] = nil
                        local slots = {}; for key in pairs(array) do if type(key) == "number" and key > index then table.insert(slots, key) end end
                        table.sort(slots)
                        for _, key in ipairs(slots) do array[key - 1] = array[key]; array[key] = nil end
                    end
                end
            end
        end
        store.records[id] = record
        return accept(record, label)
    end
    function M.observedInventory(store)
        local selected
        for _, record in pairs(store.records) do
            if type(record.data.Inventory) == "table" and (not selected
                or (record.complete and not selected.complete)
                or (record.complete == selected.complete and record.sequence > selected.sequence)) then selected = record end
        end
        if selected then return selected.data.Inventory, selected end
        return nil
    end
    function M.withProfileAbilities(inventory, data, localUserId, catalog, readCache)
        if type(inventory) ~= "table" or type(data) ~= "table" then return inventory, 0 end
        if localUserId and not M.profileScope(data, localUserId, "Data", false, {"Data"}) then return inventory, 0 end
        local views = readCache and readCache.abilityViews
        if views and views[inventory] and views[inventory][data] then return views[inventory][data], 0 end
        local roots = {data, data.Data or false, data.Profile or false}
        local collections, seen = {}, {}
        for _, root in ipairs(roots) do
            local abilities = type(root) == "table" and root.Abilities
            if type(abilities) == "table" and type(abilities.Inventory) == "table" and not seen[abilities.Inventory] then
                seen[abilities.Inventory] = true; table.insert(collections, abilities.Inventory)
            end
        end
        if #collections == 0 then return inventory, 0 end
        local combined = {}
        -- Preserve existing ability collections and let UUID deduplication merge shared entries.
        local existing = M.normalize({Abilities = inventory.Abilities, Ability = inventory.Ability}, catalog, {CollectRecords = true})
        if existing.truncated then return inventory, 0 end
        for _, record in ipairs(existing.items) do table.insert(combined, record) end
        local additions = 0
        for _, collection in ipairs(collections) do
            for key, record in pairs(collection) do
                if type(record) == "table" and (itemRecord(record) or M.uuid(key)) then
                    local owned = table.clone(record); owned.Type = "Abilities"
                    if not first(owned, uniqueFields) and M.uuid(key) then owned.UUID = M.uuid(key) end
                    table.insert(combined, owned); additions = additions + 1
                end
            end
        end
        local view = table.clone(inventory); view.Abilities = combined; view.Ability = nil
        if readCache then
            views = views or {}; readCache.abilityViews = views
            views[inventory] = views[inventory] or {}; views[inventory][data] = view
            views[view] = {[data] = view}
        end
        return view, additions
    end
    function M.categoryTotals(rows)
        local grouped, result = {}, {}
        for _, row in ipairs(rows or {}) do
            local entry = grouped[row.category]
            if not entry then
                entry = {category = row.category, quantity = 0, records = 0, groups = 0, unresolved = 0}
                grouped[row.category] = entry; table.insert(result, entry)
            end
            entry.quantity = entry.quantity + row.qty
            entry.records = entry.records + row.records; entry.groups = entry.groups + 1
            if not row.resolved then entry.unresolved = entry.unresolved + 1 end
        end
        table.sort(result, function(a, b) return a.category < b.category end)
        return result
    end
    function M.equipmentFields(data, localUserId, rootPath, predicate)
        if type(data) ~= "table" then return {} end
        if localUserId and not M.profileScope(data, localUserId, "Data", false, {"Data"}) then return {} end
        local function preview(value, depth)
            if type(value) == "string" then return string.format("%q", value:sub(1, 160)) .. (#value > 160 and "..." or "") end
            if type(value) ~= "table" then return tostring(value) end
            if depth >= 3 then return "{...}" end
            local keys = {}; for key in pairs(value) do table.insert(keys, key) end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            local parts = {}
            for index = 1, math.min(#keys, 8) do
                local key = keys[index]
                table.insert(parts, tostring(key) .. "=" .. preview(value[key], depth + 1))
            end
            if #keys > 8 then table.insert(parts, "... (" .. #keys .. " field)") end
            return "{" .. table.concat(parts, ", ") .. "}"
        end
        local result, seen = {}, {}
        local function inspect(value, path, depth)
            if type(value) ~= "table" or seen[value] or depth > 3 then return end
            seen[value] = true
            for key, child in pairs(value) do
                if type(key) == "string" then
                    local name = normalized(key)
                    local relevant
                    if predicate then relevant = predicate(name)
                    else relevant = name:find("equipped", 1, true) or name:find("enchant", 1, true)
                        or name == "equipment" or name == "loadout" or name == "equipped"
                        or name == "activerod" or name == "activebait" or name == "activeability"
                        or name == "abilities" or name == "ability" end
                    if relevant then
                        table.insert(result, path .. "." .. key .. " = " .. preview(child, 0))
                    end
                end
            end
            for _, field in ipairs({"Data", "Profile", "Equipment", "Equipped", "Loadout", "Inventory", "Metadata", "Meta",
                "Statistics", "Stats", "Wallet", "Currencies", "Currency"}) do
                if type(value[field]) == "table" then inspect(value[field], path .. "." .. field, depth + 1) end
            end
        end
        inspect(data, rootPath or "Profile", 0); table.sort(result)
        return result
    end
    function M.compactNumber(value)
        if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return nil end
        for _, unit in ipairs({{1e9, "B"}, {1e6, "M"}, {1e3, "K"}}) do
            if math.abs(value) >= unit[1] then return string.format("%.2f%s", value / unit[1], unit[2]) end
        end
        return tostring(value)
    end
    function M.playerStats(data, localUserId, includeFields)
        local result = {}
        data = type(data) == "table" and data or {}
        if localUserId and not M.profileScope(data, localUserId, "Data", false, {"Data"}) then data = {} end
        local roots = {{data = data, path = "Profile"}}
        for _, field in ipairs({"Data", "Profile"}) do
            if type(data[field]) == "table" then table.insert(roots, {data = data[field], path = field}) end
        end
        local candidates = {
            coins = {{"Coins"}, {"Coin"}, {"CoinBalance"}, {"Wallet", "Coins"}, {"Currencies", "Coins"}, {"Currency", "Coins"}},
            caught = {{"Statistics", "FishCaught"}, {"Statistics", "TotalFishCaught"}, {"Stats", "FishCaught"},
                {"TotalFishCaught"}, {"FishCaught"}, {"TotalCaught"}},
            rarestFish = {{"Statistics", "RarestFishCaught"}, {"Statistics", "RarestFishOdds"}, {"Statistics", "RarestFishChanceDenominator"},
                {"Statistics", "RarestFish"}, {"Stats", "RarestFish"}, {"RarestFishOdds"}, {"RarestFishChanceDenominator"}, {"RarestFish"}},
        }
        for key, paths in pairs(candidates) do
            local slot = {status = "unknown", display = "Belum terbaca", source = "Field belum tersedia"}
            for _, root in ipairs(roots) do
                for _, path in ipairs(paths) do
                    local raw = M.path(root.data, path)
                    if raw ~= nil then
                        local display, value, probability, oddsDenominator
                        if key ~= "rarestFish" then
                            local amount = (type(raw) == "number" or type(raw) == "string") and tonumber(raw)
                            if amount and amount >= 0 and amount < math.huge and amount == amount then
                                value = amount; display = M.compactNumber(amount)
                            end
                        elseif path[#path] == "RarestFishCaught" then
                            -- This observed field stores a probability, not an item ID or denominator.
                            if type(raw) == "number" and raw > 0 and raw <= 1 then
                                local denominator = 1 / raw
                                if denominator < math.huge then
                                    -- Reciprocal arithmetic can land just below an integer/unit boundary.
                                    -- Round only the display when that difference is floating-point noise.
                                    local displayDenominator = denominator
                                    local nearest = math.floor(denominator + 0.5)
                                    if math.abs(denominator - nearest) <= denominator * 1e-12 then displayDenominator = nearest end
                                    local formatted = M.compactNumber(displayDenominator)
                                        :gsub("%.00([KMB])$", "%1"):gsub("(%.[0-9])0([KMB])$", "%1%2")
                                    value = raw; probability = raw; oddsDenominator = denominator
                                    display = "1/" .. formatted
                                end
                            end
                        elseif type(raw) == "number" and raw >= 0 and raw < math.huge and raw == raw then
                            value = raw
                            display = path[#path] == "RarestFishChanceDenominator" and raw > 0
                                and ("1/" .. M.compactNumber(raw)) or tostring(raw)
                        elseif type(raw) == "string" and clean(raw) ~= "" then value = raw; display = clean(raw)
                        elseif type(raw) == "table" then
                            value = M.copyData(raw, 256)
                            local name = first(raw, {"Name", "DisplayName", "FishName"})
                            local odds = first(raw, {"Odds", "OddsText", "ChanceText"})
                            local denominator = first(raw, {"ChanceDenominator", "OddsDenominator", "Denominator"})
                            if type(denominator) == "number" and denominator >= 1 and denominator < math.huge then
                                odds = "1/" .. M.compactNumber(denominator)
                            end
                            if type(odds) == "string" then display = (type(name) == "string" and (name .. " | ") or "") .. odds
                            elseif type(name) == "string" then display = name end
                        end
                        if display then
                            slot = {status = "known", value = value, display = display,
                                probability = probability, oddsDenominator = oddsDenominator,
                                source = root.path .. "." .. table.concat(path, ".")}
                            break
                        end
                    end
                end
                if slot.status == "known" then break end
            end
            result[key] = slot
        end
        result.fields = includeFields == false and {} or M.equipmentFields(data, localUserId, "Profile", function(name)
            return name == "coins" or name == "coin" or name == "coinbalance"
                or name:find("caught", 1, true) or name:find("rarest", 1, true)
        end)
        return result
    end
    local equipmentSlots = {
        rod = {category = "Fishing Rods", fields = {"EquippedRodUUID", "EquippedFishingRodUUID", "EquippedFishingRod", "EquippedRod", "EquippedRodId", "EquippedFishingRodId", "ActiveRod"},
            short = {"FishingRod", "Rod", "FishingRods", "Rods", "Fishing Rods", "Fishing Rod"}},
        bait = {category = "Baits", fields = {"EquippedBait", "EquippedBaitId", "ActiveBait"}, short = {"Bait", "Baits"}},
        ability = {category = "Abilities", fields = {"EquippedAbility", "EquippedAbilities", "EquippedAbilityId", "ActiveAbility"},
            short = {"Ability", "Abilities"}},
        pet = {category = "Pets", fields = {"EquippedPetUUID", "EquippedPet", "EquippedPetId"}, short = {"Pet", "Pets"}},
    }
    local enchantFields = {"Enchantments", "Enchants", "Enchantment", "Enchant", "EnchantId", "EnchantmentId"}
    function M.enchantNames(value, catalog)
        if value == nil then return nil end
        local names, seen = {}, {}
        local function add(item, level)
            if type(item) == "table" then
                level = item.Level or level
                item = item.Name or item.DisplayName or item.Id or item.EnchantId or item.EnchantmentId
            end
            if item == false or item == nil or item == 0 or item == "" or item == "\0" then return end
            if type(item) ~= "string" and type(item) ~= "number" then return end
            local text = clean(item)
            if normalized(text) == "none" or text == "0" then return end
            local name = catalog.enchants[tostring(item)] or (tonumber(item) and "Enchant #" .. text or text)
            if tonumber(level) and tonumber(level) > 0 then name = name .. " (Lv." .. tostring(level) .. ")" end
            if not seen[name] then seen[name] = true; table.insert(names, name) end
        end
        if type(value) == "table" then
            if value.Name or value.Id or value.EnchantId or value.EnchantmentId then add(value)
            elseif isArray(value) then for _, item in ipairs(value) do add(item) end
            else for key, item in pairs(value) do
                if item == true then add(key)
                elseif type(item) == "table" then add(item)
                elseif tonumber(item) and (catalog.enchants[tostring(key)] or type(key) == "string") then add(key, item)
                else add(item) end
            end end
        else add(value) end
        table.sort(names)
        return #names > 0 and table.concat(names, ", ") or "Tidak ada"
    end
    function M.enchantSlots(primary, secondary, catalog, hasPrimary, hasSecondary)
        local result = {first = "Belum terbaca", second = "Belum terbaca", firstKnown = false, secondKnown = false}
        local namedSlots = false
        local function set(index, value)
            result[index] = M.enchantNames(value, catalog) or "Belum terbaca"
            result[index .. "Known"] = value ~= nil
        end
        if hasPrimary then
            if type(primary) == "table" and not (primary.Name or primary.DisplayName or primary.Id or primary.EnchantId or primary.EnchantmentId) then
                if next(primary) == nil then set("first", false); set("second", false)
                elseif primary[1] ~= nil or primary[2] ~= nil then
                    if primary[1] ~= nil then set("first", primary[1]) end
                    if primary[2] ~= nil then set("second", primary[2])
                    end
                else
                    local firstSlot = first(primary, {"Primary", "First", "Slot1"})
                    local secondSlot = first(primary, {"Secondary", "Second", "Slot2"})
                    if firstSlot ~= nil or secondSlot ~= nil then
                        namedSlots = true
                        if firstSlot ~= nil then set("first", firstSlot) end
                        if secondSlot ~= nil then set("second", secondSlot) end
                    else
                        local count = 0; for _ in pairs(primary) do count = count + 1 end
                        if count == 1 then set("first", primary) end
                    end
                end
            else set("first", primary) end
        end
        if hasSecondary then set("second", secondary) end
        result.aggregate = hasPrimary and M.enchantNames(primary, catalog) or nil
        if namedSlots then
            local names = {}
            if result.firstKnown and result.first ~= "Tidak ada" then table.insert(names, result.first) end
            if result.secondKnown and result.second ~= "Tidak ada" then table.insert(names, result.second) end
            result.aggregate = #names > 0 and table.concat(names, ", ") or "Tidak ada"
        end
        local secondName = hasSecondary and M.enchantNames(secondary, catalog) or nil
        if secondName and secondName ~= "Tidak ada" then
            result.aggregate = result.aggregate and result.aggregate ~= "Tidak ada" and (result.aggregate .. ", " .. secondName) or secondName
        end
        result.aggregate = result.aggregate or (hasSecondary and "Tidak ada" or "Belum terbaca")
        return result
    end
    function M.equipment(data, inventory, catalog, localUserId, readCache)
        local result = {}
        if localUserId and type(data) == "table" then
            local owns = M.profileScope(data, localUserId, "Data", false, {"Data"})
            if not owns then data = {} end
        end
        data = type(data) == "table" and data or {}
        inventory = M.withProfileAbilities(inventory or {}, data, localUserId, catalog, readCache)
        local sources = {{data = data, path = "Profile"}}
        for _, key in ipairs({"Data", "Profile"}) do
            if type(data[key]) == "table" then table.insert(sources, {data = data[key], path = key}) end
        end
        local roots = table.clone(sources)
        for _, root in ipairs(roots) do
            for _, key in ipairs({"Equipment", "Equipped", "Loadout", "EquippedItems", "Inventory"}) do
                if type(root.data[key]) == "table" then table.insert(sources, {data = root.data[key], path = root.path .. "." .. key, short = key ~= "Inventory"}) end
            end
        end
        local flat = readCache and readCache[inventory] or M.normalize(inventory or {}, catalog, {CollectRecords = true, Checkpoint = readCache and readCache.Checkpoint})
        if readCache then readCache[inventory] = flat end
        local checkpoint = readCache and readCache.Checkpoint
        local ownership = readCache and readCache.ownership
        if not ownership or ownership.flat ~= flat then
            ownership = {flat = flat, byUUID = {}, byCategory = {}}
            for _, record in ipairs(flat.items) do
                if checkpoint then checkpoint() end
                local uid = M.uuid(record.UUID)
                if uid then ownership.byUUID[uid] = record end
                local category = ownership.byCategory[record.Type] or {}; ownership.byCategory[record.Type] = category
                table.insert(category, record)
            end
            if readCache then readCache.ownership = ownership end
        end
        local ownedByUUID = ownership.byUUID
        local function sharedEquipped(category)
            local matches, seen = {}, {}
            for _, root in ipairs(roots) do
                local shared = root.data.EquippedItems
                if type(shared) == "table" then
                    for key, reference in pairs(shared) do
                        if checkpoint then checkpoint() end
                        local uid = M.uuid(type(reference) == "table" and first(reference, uniqueFields) or reference)
                            or (reference == true and M.uuid(key))
                        local owned = uid and ownedByUUID[uid]
                        if owned and owned.Type == category and not seen[uid] then
                            seen[uid] = true
                            table.insert(matches, {uuid = uid, record = owned, path = root.path .. ".EquippedItems"})
                        end
                    end
                end
            end
            return matches
        end
        local function resolve(value, category)
            if value == false or value == 0 or value == "" or value == "\0" then return {name = "Tidak ada", status = "none"} end
            local uuid = M.uuid(type(value) == "table" and first(value, uniqueFields) or value)
            local id = type(value) == "table" and first(value, idFields) or (not uuid and tonumber(value))
            local name = type(value) == "table" and first(value, nameFields) or (type(value) == "string" and not uuid and not id and value)
            local matches = {}
            for _, record in ipairs(ownership.byCategory[category] or {}) do
                if checkpoint then checkpoint() end
                if record.Type == category and ((uuid and record.UUID == uuid) or
                    (not uuid and id and tostring(record.Id) == tostring(id)) or
                    (not uuid and not id and name and record.Name == name)) then table.insert(matches, record) end
            end
            local owned = #matches == 1 and matches[1] or nil
            local entry = M.lookup(catalog, id or (owned and owned.Id), name or (owned and owned.Name), category)
            local slot = {uuid = uuid or (owned and M.uuid(owned.UUID)), id = id or (owned and owned.Id), record = owned, reference = value,
                name = (entry and entry.name) or name or (owned and owned.Name) or (uuid and "UUID " .. uuid)
                    or (id and category .. " #" .. tostring(id)) or "Belum terbaca",
                status = (entry or name or uuid or id) and "known" or "unknown"}
            -- A record supplied by the explicit equipped field belongs to that active slot.
            if type(value) == "table" and (id or name or uuid) then slot.equippedRecord = value end
            return slot
        end
        for key, config in pairs(equipmentSlots) do
            local value, proof
            for _, source in ipairs(sources) do
                local fields = source.short and config.short or config.fields
                for _, field in ipairs(fields) do
                    if source.data[field] ~= nil then value = source.data[field]; proof = source.path .. "." .. field; break end
                end
                if proof then break end
            end
            if key == "ability" and value == nil then
                for _, root in ipairs(roots) do
                    if type(root.data.Abilities) == "table" and root.data.Abilities.Equipped ~= nil then
                        value = root.data.Abilities.Equipped; proof = root.path .. ".Abilities.Equipped"; break
                    end
                end
            end
            if key == "rod" and value == nil then
                for _, root in ipairs(roots) do
                    local uid = M.uuid(root.data.EquippedId)
                    local owned = uid and ownedByUUID[uid]
                    if M.category(root.data.EquippedType) == "Fishing Rods" and owned and owned.Type == "Fishing Rods" then
                        value = uid; proof = root.path .. ".EquippedId (EquippedType Fishing Rods; UUID dimiliki)"; break
                    end
                end
            end
            local shared = sharedEquipped(config.category)
            if value == nil and #shared > 0 then
                if key == "ability" then
                    value = {}; for _, match in ipairs(shared) do table.insert(value, match.uuid) end
                    proof = shared[1].path .. " (UUID dimiliki; kategori Abilities)"
                elseif #shared == 1 then
                    value = shared[1].uuid; proof = shared[1].path .. " (UUID dimiliki; kategori " .. config.category .. ")"
                end
            elseif key == "rod" and #shared == 1 and value ~= false and value ~= 0 and value ~= "" and value ~= "\0" then
                local uid, id
                if type(value) == "table" then uid = M.uuid(first(value, uniqueFields)); id = first(value, idFields)
                else uid = M.uuid(value); id = tonumber(value) end
                if not uid and id and tostring(id) == tostring(shared[1].record.Id) then
                    if type(value) == "table" then value = table.clone(value); value.UUID = shared[1].uuid
                    else value = shared[1].uuid end
                    proof = proof .. " + " .. shared[1].path .. " (UUID sesuai Id rod)"
                end
            end
            local slot
            if value == nil then slot = {name = "Belum terbaca", status = "unknown"}
            elseif type(value) == "table" and not itemRecord(value) then
                local names, resolvedItems = {}, {}
                for index, item in pairs(value) do
                    local resolved = resolve(item == true and index or item, config.category)
                    if resolved.status ~= "unknown" then table.insert(names, resolved.name); table.insert(resolvedItems, resolved) end
                end
                if key ~= "ability" and #resolvedItems == 1 then slot = resolvedItems[1]
                elseif key ~= "ability" and #resolvedItems > 1 then slot = {name = "Belum terbaca (beberapa kandidat)", status = "unknown"}
                else
                    table.sort(names); slot = {name = #names > 0 and table.concat(names, ", ") or "Tidak ada",
                        status = #names > 0 and "known" or "none", items = resolvedItems}
                end
            else slot = resolve(value, config.category) end
            slot.source = proof or "Field equip belum tersedia"; slot.category = config.category; result[key] = slot
        end
        local rod = result.rod
        local enchant, found, secondEnchant, secondFound
        for _, record in ipairs({rod.equippedRecord or false, rod.record or false}) do
            if type(record) == "table" then
                if not found then
                    enchant = first(record, enchantFields)
                    if enchant == nil then enchant = first(metadata(record), enchantFields) end
                    if enchant ~= nil then found = true end
                end
                if not secondFound then
                    secondEnchant = first(record, secondaryEnchantFields)
                    if secondEnchant == nil then secondEnchant = first(metadata(record), secondaryEnchantFields) end
                    if secondEnchant ~= nil then secondFound = true end
                end
            end
        end
        if not found then
            for _, root in ipairs(roots) do
                for _, field in ipairs({"EquippedRodEnchantments", "EquippedRodEnchants", "EquippedRodEnchant"}) do
                    if root.data[field] ~= nil then enchant = root.data[field]; found = true; break end
                end
                if not found and rod.uuid then
                    for _, field in ipairs({"RodEnchantments", "FishingRodEnchantments"}) do
                        local map = root.data[field]
                        if type(map) == "table" and map[rod.uuid] ~= nil then enchant = map[rod.uuid]; found = true; break end
                    end
                end
                if found then break end
            end
        end
        local slots = M.enchantSlots(enchant, secondEnchant, catalog, found, secondFound)
        rod.enchants = rod.status == "none" and "Tidak ada rod aktif" or slots.aggregate
        rod.enchantKnown = found or secondFound or rod.status == "none"
        rod.enchant1 = rod.status == "none" and "Tidak ada rod aktif" or slots.first
        rod.enchant2 = rod.status == "none" and "Tidak ada rod aktif" or slots.second
        rod.enchant1Known = slots.firstKnown or rod.status == "none"
        rod.enchant2Known = slots.secondKnown or rod.status == "none"
        rod.enchantFields = {}
        for _, entry in ipairs({{rod.equippedRecord, "EquippedRod"}, {rod.record, "OwnedRod"}}) do
            for _, line in ipairs(M.equipmentFields(entry[1], nil, entry[2])) do table.insert(rod.enchantFields, line) end
        end
        return result
    end
    local function equipmentPath(value)
        local path = {}
        if type(value) == "string" then for key in value:gmatch("[^%.]+") do table.insert(path, tonumber(key) or key) end
        elseif type(value) == "table" then for _, key in ipairs(value) do
            if type(key) ~= "string" and type(key) ~= "number" then return nil end; table.insert(path, key)
        end else return nil end
        if path[1] == "Data" or path[1] == "Profile" then table.remove(path, 1) end
        if #path > 16 then return nil end
        local key = path[1] == "Inventory" and path[2] or path[1]
        if key == "Abilities" then
            local offset = path[1] == "Inventory" and 2 or 1
            if #path == offset or path[offset + 1] == "Equipped" or path[offset + 1] == "Inventory"
                or path[offset + 1] == "Active" then return path end
        end
        if key == "Equipment" or key == "Equipped" or key == "Loadout" or key == "EquippedItems" or key == "EquippedId" or key == "EquippedType"
            or key == "RodEnchantments" or key == "FishingRodEnchantments" or tostring(key):match("^EquippedRodEnchant") then return path end
        for _, config in pairs(equipmentSlots) do if table.find(config.fields, key) then return path end end
        return nil
    end
    function M.isEquipmentPath(value) return not M.isRemovedEquipmentPath(value) and equipmentPath(value) ~= nil end
    -- Only changes to fields used by the inventory/equipment projection cancel a read.
    -- Coordinate annotations stay passive; removed equipment slots are ignored.
    local function sourcePath(value)
        local parts = {}
        if type(value) == "string" then
            for key in value:gmatch("[^%.]+") do table.insert(parts, tonumber(key) or key) end
        elseif type(value) == "table" then
            for _, key in ipairs(value) do
                if type(key) ~= "string" and type(key) ~= "number" then return nil end
                table.insert(parts, key)
                if #parts > 24 then return nil end
            end
        else return nil end
        return parts
    end
    function M.equipmentChangeRelevant(value, remote, update)
        if M.isRemovedEquipmentPath and M.isRemovedEquipmentPath(value) then return false end
        local path = sourcePath(value)
        if not path then return true end -- Unknown notifications invalidate conservatively.
        if path[1] == "Data" or path[1] == "Profile" then table.remove(path, 1) end
        local function annotation(parts)
            return M.isRemovedEquipmentPath and M.isRemovedEquipmentPath(parts)
                or parts[1] == "Loadout" and (parts[2] == "LastCoordinate"
                    or parts[2] == "LastCharacterCoordinate" or parts[2] == "LastCharacterLocationName")
        end
        if annotation(path) then return false end
        if remote == "Update" and type(update) == "table" then
            local found = false
            for key in pairs(update) do
                found = true
                local child = table.clone(path); table.insert(child, key)
                if not annotation(child) then return true end
            end
            if found then return false end
        end
        return true
    end
    function M.sourceChangeRelevant(value, inventoryPaths, channel)
        local path = sourcePath(value)
        if not path or #path == 0 then return true end
        if M.isRemovedEquipmentPath(path) then return false end
        if channel == "Inventory" or channel == "Backpack" then return true end
        for _, candidate in ipairs(inventoryPaths) do
            local matches = true
            for index = 1, math.min(#path, #candidate) do
                if path[index] ~= candidate[index] then matches = false; break end
            end
            if matches then return true end -- Match the whole prefix, including replacements of ancestors.
        end
        return M.isEquipmentPath(value) and M.equipmentChangeRelevant(value) or false
    end

    function M.tradeChoices(inventory, catalog, prepared, checkpoint)
        local flat = prepared or M.normalize(inventory or {}, catalog, {CollectRecords = true, Checkpoint = checkpoint})
        local byKey, canonicalRows = {}, {}
        for _, row in ipairs(flat.rows) do canonicalRows[row.key] = row end
        for _, record in ipairs(flat.items) do
            if checkpoint then checkpoint() end
            local row = canonicalRows[record.GroupKey]
            if row then
                local facts = M.tradeEligibility(record, M.lookup(catalog, record.Id, record.Name, record.Type))
                local trade = byKey[row.key] or {verifiedUnits = 0, unknownUnits = 0, notTradableUnits = 0}
                local field = facts.status == "tradable" and "verifiedUnits" or facts.status == "unknown" and "unknownUnits" or "notTradableUnits"
                trade[field] = trade[field] + record.Quantity
                trade.rap = facts.rap or trade.rap
                byKey[row.key] = trade
            end
        end
        local result = {}
        for _, canonical in ipairs(flat.rows) do
            if checkpoint then checkpoint() end
            local row = prepared and table.clone(canonical) or canonical
            row.trade = byKey[row.key] or {verifiedUnits = 0, unknownUnits = 0, notTradableUnits = 0}
            if #row.instances > 0 and row.trade.verifiedUnits + row.trade.unknownUnits > 0 then table.insert(result, row) end
        end
        return result
    end
    function M.itemReady(row)
        return type(row) == "table" and row.resolved == true and type(row.name) == "string"
            and row.name:match("%S") ~= nil and not row.name:match("^Item #%d+$")
            and type(row.icon) == "string" and row.icon ~= "" and type(row.key) == "string"
            and type(row.qty) == "number" and row.qty > 0 and row.qty % 1 == 0
    end
    function M.publishInventory(snapshot, choices, checkpoint)
        if not snapshot or snapshot.partial ~= false or snapshot.truncated == true then return nil end
        local result = table.clone(snapshot)
        result.rows, result.total, result.pendingGroups, result.pendingUnits = {}, 0, 0, 0
        result.sourceTotal, result.progressive = snapshot.total, true
        local accepted, categories = {}, {}
        for _, row in ipairs(snapshot.rows or {}) do
            if checkpoint then checkpoint() end
            if M.itemReady(row) then
                table.insert(result.rows, row); accepted[row.key] = true; result.total += row.qty
                local category = categories[row.category] or {category = row.category, quantity = 0, records = 0, groups = 0, unresolved = 0}
                category.quantity += row.qty; category.records += row.records or 0; category.groups += 1
                categories[row.category] = category
            else result.pendingGroups += 1; result.pendingUnits += row.qty or 0 end
        end
        result.categories = {}
        for _, category in pairs(categories) do table.insert(result.categories, category) end
        table.sort(result.categories, function(a,b) return a.category < b.category end)
        local available = {}
        for _, row in ipairs(choices or {}) do
            if checkpoint then checkpoint() end
            if accepted[row.key] and M.itemReady(row) then table.insert(available, row) end
        end
        return result, available
    end

    function M.fishingObserve(history, profile, flat, sample, checkpoint)
        history=history or {caught=0,classified=0,secret=0,forgotten=0,secretGapSum=0,secretGapCount=0,forgottenGapSum=0,forgottenGapCount=0}
        local root=profile or {}
        for _,key in ipairs({"Data","Profile"}) do if type(root[key])=="table" and type(root[key].Statistics)=="table" then root=root[key];break end end
        local analytics=type(root.Analytics)=="table" and root.Analytics or {}
        local caught=sample.caught
        local function number(value) return type(value)=="number" and value==value and value>=0 and value<1e15 and value%1==0 and value or nil end
        caught=number(caught)
        if not caught then history.previous=nil;return history,nil end
        local current={caught=caught,source=sample.source,at=sample.at,complete=sample.complete,trading=sample.trading}
        local prior=history.previous
        for _,tier in ipairs({"secret","forgotten"}) do
            local suffix=tier=="secret" and "Secret" or "Forgotten"
            current[tier.."At"]=number(analytics["Last"..suffix.."Timestamp"])
            current[tier.."Since"]=number(analytics["FishSinceLast"..suffix])
        end
        local count=prior and caught-prior.caught or 0
        -- Reuse an inventory identity when no item data changed. Only normalized
        -- personal fish records participate; no additional source discovery.
        if prior and (prior.items==flat.items or sample.inventory~=nil and prior.inventory==sample.inventory and prior.catalog==sample.catalog) then current.stock=prior.stock else
            current.stock={}
            for _,record in ipairs(flat.items or {}) do
                if checkpoint then checkpoint() end
                if record.Type=="Fish" and M.uuid(record.UUID) then
                    local rarity=tostring(record.Rarity):lower();local tier=(rarity=="secret" or rarity=="tier 7") and "secret" or (rarity=="forgotten" or rarity=="tier 8") and "forgotten" or nil
                    current.stock[record.UUID]={qty=record.Quantity,tier=tier}
                end
            end
        end
        current.items=flat.items
        current.inventory=sample.inventory;current.catalog=sample.catalog
        local continuous=prior and prior.source==sample.source and count>=0 and sample.at>=prior.at and sample.at-prior.at<=300
        if not continuous then history.secretLastIndex=nil;history.forgottenLastIndex=nil end
        if continuous and count>0 then
            history.caught+=count
            local added,removed,rare=0,false,{secret=0,forgotten=0}
            for uuid,entry in pairs(current.stock) do
                if checkpoint then checkpoint() end
                local old=prior.stock[uuid];local delta=entry.qty-(old and old.qty or 0)
                if delta>0 then added+=delta;if entry.tier then rare[entry.tier]+=delta end end
                if delta<0 then removed=true end
            end
            for uuid in pairs(prior.stock) do if not current.stock[uuid] then removed=true end end
            local confirmed=sample.complete and prior.complete and not sample.trading and not prior.trading and not removed and added==count
            for _,tier in ipairs({"secret","forgotten"}) do
                if rare[tier]>0 then
                    local time=current[tier.."At"];local old=prior[tier.."At"]
                    local since=current[tier.."Since"];local oldSince=prior[tier.."Since"]
                    if not ((time and old and time>old) or (since and oldSince and since~=oldSince and since<oldSince+count)) then confirmed=false end
                end
            end
            if confirmed then history.classified+=count;history.secret+=rare.secret;history.forgotten+=rare.forgotten end
            for _,tier in ipairs({"secret","forgotten"}) do
                local since=current[tier.."Since"];local oldSince=prior[tier.."Since"]
                local at=current[tier.."At"];local oldAt=prior[tier.."At"]
                local updated=(at and oldAt and at>oldAt) or (since and oldSince and since~=oldSince and since<oldSince+count)
                local lastIndex=since and caught-since
                if updated and lastIndex and lastIndex>=prior.caught and lastIndex<=caught then
                    local previous=history[tier.."LastIndex"] or (oldSince and prior.caught-oldSince)
                    -- A batch with several rare fish cannot reveal each intermediate gap.
                    if confirmed and rare[tier]==1 and previous and lastIndex>previous then
                        history[tier.."GapSum"]+=lastIndex-previous;history[tier.."GapCount"]+=1
                    end
                    history[tier.."LastIndex"]=lastIndex
                end
            end
        end
        history.previous=current
        local report={runId=sample.runId,at=sample.at,totalCaught=caught}
        for _,key in ipairs({"caught","classified","secret","forgotten","secretGapSum","secretGapCount","forgottenGapSum","forgottenGapCount"}) do report[key]=history[key] end
        for _,tier in ipairs({"secret","forgotten"}) do report[tier.."At"]=current[tier.."At"];report[tier.."Since"]=current[tier.."Since"] end
        local unchanged=history.lastReport~=nil
        if unchanged then for key,value in pairs(report) do if key~="at" and history.lastReport[key]~=value then unchanged=false;break end end end
        if unchanged then for key in pairs(history.lastReport) do if key~="at" and report[key]==nil then unchanged=false;break end end end
        if unchanged and sample.at-history.lastReport.at<10800 then return history,history.lastReport end
        history.lastReport=report;return history,report
    end
    function M.tradeItemKey(row) return row.category .. "\0" .. tostring(row.id) .. "\0" .. row.name end
    function M.tradeRequestMatches(request, key)
        if request.byItem then return key:match("^([^%z]*%z[^%z]*%z[^%z]*)") == request.key end
        return request.key == key
    end
    function M.tradeReportedAmounts(values, requests)
        local totals={}
        for key,quantity in pairs(values or {}) do
            for _,request in ipairs(requests or {}) do if M.tradeRequestMatches(request,key) then totals[request.key]=(totals[request.key] or 0)+quantity;break end end
        end
        local result={};for key,quantity in pairs(totals) do table.insert(result,{key=key,quantity=quantity}) end
        table.sort(result,function(a,b)return a.key<b.key end);return result
    end
    function M.tradePlan(inventory, catalog, requests, context)
        context = context or {}
        local localId, targetId = tonumber(context.localUserId), tonumber(context.targetUserId)
        if not localId or not targetId or localId <= 0 or targetId <= 0 or localId % 1 ~= 0 or targetId % 1 ~= 0 or localId == targetId then return nil, "Target player tidak valid" end
        if context.fullSnapshot ~= true or (context.catalogReady ~= true and context.itemCatalogReady ~= true) then return nil, "Tunggu pembacaan stok akun dan informasi item" end
        if type(requests) ~= "table" or #requests == 0 or #requests > 1000 then return nil, "Pilih item dan jumlah; maksimal 1000 pilihan" end
        local flat = M.normalize(inventory, catalog, {CollectRecords = true})
        if flat.truncated then return nil, "Snapshot terpotong" end
        local groups, canonicalRows = {}, {}
        for _, row in ipairs(flat.rows) do canonicalRows[row.key] = row end
        for _, record in ipairs(flat.items) do
            local uuid = M.uuid(record.UUID)
            local meta = metadata(record)
            local locked = record.Locked == true or record.TradeLocked == true or meta.Locked == true or meta.TradeLocked == true
            local qty = tonumber(record.Quantity)
            local eligibility = M.tradeEligibility(record, M.lookup(catalog, record.Id, record.Name, record.Type))
            if uuid and qty and qty > 0 and qty % 1 == 0 and not locked and eligibility.status ~= "notTradable" then
                local row = canonicalRows[record.GroupKey]
                if row then
                    groups[row.key] = groups[row.key] or {}
                    table.insert(groups[row.key], {uuid = uuid, id = record.Id, name = M.displayItemName(row),
                        category = record.Type, key=row.key, mutation = row.mutation, available = qty, sourceQuantity = qty, trade = eligibility})
                end
            end
        end
        for _, group in pairs(groups) do table.sort(group, function(a, b) return a.uuid < b.uuid end) end
        local plan = {localUserId = localId, targetUserId = targetId, units = {}, batches = {}, total = 0,
            maxSlots = 20, quantityPerSlot = 1, requiresUnitSelection = false, unverifiedEligibility = false,
            status = "planned", requests = M.copyData(requests, 5000)}
        for _, request in ipairs(requests) do
            if type(request) ~= "table" or type(request.key) ~= "string" then return nil, "Pilihan item tidak valid" end
            local sources={}
            for key,group in pairs(groups) do if M.tradeRequestMatches(request,key) then
                if context.itemCatalogReady == true and not M.itemReady(canonicalRows[key]) then return nil, "Informasi item pilihan belum siap" end
                for _,source in ipairs(group) do table.insert(sources,source) end
            end end
            if not request.byItem and context.itemCatalogReady == true and not M.itemReady(canonicalRows[request.key]) then return nil, "Informasi item pilihan belum siap" end
            table.sort(sources,function(a,b)return a.key==b.key and a.uuid<b.uuid or a.key<b.key end)
            local wanted = tonumber(request.quantity)
            if not wanted or wanted <= 0 or wanted % 1 ~= 0 or wanted > 1000 or plan.total + wanted > 1000 then return nil, "Jumlah harus bilangan bulat 1–1000; maksimal 1000 unit per rencana" end
            local remaining = wanted
            for _, source in ipairs(sources) do
                local take = math.min(remaining, source.available)
                for _ = 1, take do
                    local sourceIndex = source.sourceQuantity - source.available + 1
                    table.insert(plan.units, {sourceUUID = source.uuid, id = source.id, name = source.name, category = source.category,
                        key = source.key, mutation = source.mutation, quantity = 1, sourceQuantity = source.sourceQuantity, sourceUnitIndex = sourceIndex,
                        tradeStatus = source.trade.status, rap = source.trade.rap, tradeSource = source.trade.source,
                        requiresUnitSelection = source.sourceQuantity > 1})
                    source.available = source.available - 1
                end
                remaining = remaining - take
                if take > 0 and source.sourceQuantity > 1 then plan.requiresUnitSelection = true end
                if take > 0 and source.trade.status ~= "tradable" then plan.unverifiedEligibility = true end
                if remaining == 0 then break end
            end
            if remaining > 0 then return nil, "Unit tidak cukup, dikunci, atau tidak tradable: kurang " .. remaining end
            plan.total = plan.total + wanted
        end
        for index, unit in ipairs(plan.units) do
            local batch = math.floor((index - 1) / 20) + 1
            plan.batches[batch] = plan.batches[batch] or {index = batch, slots = {}, targetUserId = targetId, status = "awaitingInvitationAcceptance"}
            table.insert(plan.batches[batch].slots, unit)
        end
        return plan
    end
    function M.tradeJournal(localUserId, targetUserId, plan)
        return {localUserId = localUserId, targetUserId = targetUserId, recording = false,
            targetAcceptance = "unverified", completion = "unverified"}
    end
    function M.tradeExecutionBatches(plan)
        local batches, latest = {}, {}
        for _, unit in ipairs(plan.units or {}) do
            local index = latest[unit.sourceUUID] and latest[unit.sourceUUID] + 1 or 1
            while batches[index] and #batches[index].slots >= 20 do index = index + 1 end
            batches[index] = batches[index] or {index = index, slots = {}, targetUserId = plan.targetUserId, status = "pending"}
            table.insert(batches[index].slots, unit); latest[unit.sourceUUID] = index
        end
        return batches
    end
    function M.tradeOfferMatches(summary, slots, requireUnitQuantity)
        if not summary or summary.scopeMatches ~= true then return false, "Peserta sesi tidak cocok" end
        if summary.localTokens ~= 0 or summary.targetTokens ~= 0 then return false, "Offer token berubah" end
        local own, other = summary.localOffer, summary.targetOffer
        if not own or not other or not own.itemsAvailable or not other.itemsAvailable or own.truncated or other.truncated
            or own.unmapped ~= 0 or other.unmapped ~= 0 then return false, "Offer belum dapat diperiksa lengkap" end
        if other.cards ~= 0 then return false, "Offer target berubah; rencana ini untuk mengirim item" end
        local expected, seen = {}, {}
        for _, slot in ipairs(slots) do
            if expected[slot.sourceUUID] then return false, "UUID berulang dalam satu sesi" end
            expected[slot.sourceUUID] = slot
        end
        for _, card in ipairs(own.items) do
            local slot = expected[card.sourceUUID]
            if not slot or seen[card.sourceUUID] or card.itemType ~= (slot.itemType or slot.category) then
                return false, "UUID/jenis offer berbeda dari rencana"
            end
            seen[card.sourceUUID] = true
            if requireUnitQuantity and card.quantity ~= 1 and not (card.quantity == "unverified" and slot.sourceQuantity == 1) then
                return false, "Jumlah offer stack belum terbukti 1 unit; konfirmasi dihentikan"
            end
        end
        if own.cards ~= #slots then return false, "Jumlah kartu offer berbeda dari rencana" end
        return true
    end
    function M.tradeSessionSummary(data, localUserId, targetUserId, channel)
        -- Shape observed in the supplied TradeController, not the personal inventory channel.
        local localId, targetId = tonumber(localUserId), tonumber(targetUserId)
        if not localId or not targetId or localId <= 0 or targetId <= 0 or localId % 1 ~= 0 or targetId % 1 ~= 0
            or localId == targetId then return nil, "Identitas sesi tidak valid" end
        if type(channel) ~= "string" or channel == "" then return nil, "Channel sesi belum diketahui" end
        if type(data) ~= "table" or type(data.PlayerList) ~= "table" or type(data.Players) ~= "table" then
            return nil, "Bentuk sesi trade belum tersedia"
        end
        local seen, count = {}, 0
        for key, participant in pairs(data.PlayerList) do
            if key ~= 1 and key ~= 2 then return nil, "PlayerList bukan dua peserta" end
            local ok, id = pcall(function() return tonumber(participant.UserId) end)
            if not ok or (id ~= localId and id ~= targetId) or seen[id] then return nil, "Peserta sesi tidak cocok" end
            count = count + 1; seen[id] = true
        end
        if count ~= 2 or not seen[localId] or not seen[targetId] then return nil, "Peserta sesi tidak lengkap" end
        local localOffer, targetOffer = data.Players[tostring(localId)], data.Players[tostring(targetId)]
        if type(localOffer) ~= "table" or type(targetOffer) ~= "table" then return nil, "Offer peserta belum tersedia" end
        local playerCount = 0
        for key in pairs(data.Players) do
            if key ~= tostring(localId) and key ~= tostring(targetId) then return nil, "Offer memuat peserta lain" end
            playerCount = playerCount + 1
        end
        if playerCount ~= 2 then return nil, "Offer peserta tidak lengkap" end
        local function boolean(value) if type(value) == "boolean" then return value end; return "unverified" end
        local function number(value)
            if type(value) == "number" and value == value and value >= 0 and value < math.huge then return value end
            return "unverified"
        end
        local function items(offer)
            local result = {items = {}, cards = 0, itemsAvailable = type(offer.Items) == "table", unmapped = 0}
            local visited = 0
            for itemType, records in pairs(type(offer.Items) == "table" and offer.Items or {}) do
                if type(itemType) == "string" and type(records) == "table" then
                    for _, record in pairs(records) do
                        visited = visited + 1
                        if visited > 40 then result.truncated = true; break end
                        local uuid = type(record) == "table" and M.uuid(record.UUID)
                        if uuid then
                            local quantity = number(record.Quantity)
                            if quantity == 0 then quantity = "unverified" end
                            table.insert(result.items, {itemType = itemType, sourceUUID = uuid,
                                quantity = quantity})
                        else result.unmapped = result.unmapped + 1 end
                    end
                else result.unmapped = result.unmapped + 1 end
                if visited > 40 then break end
            end
            table.sort(result.items, function(a, b)
                if a.itemType ~= b.itemType then return a.itemType < b.itemType end
                return a.sourceUUID < b.sourceUUID
            end)
            result.cards = #result.items
            return result
        end
        local summary = {channel = channel, localUserId = localId, targetUserId = targetId, scopeMatches = true,
            source = "Replion trade session", completion = "unverified",
            playersReady = boolean(data.PlayersReady), localReady = boolean(localOffer.IsReady),
            targetReady = boolean(targetOffer.IsReady), localConfirmed = boolean(localOffer.IsConfirmed),
            targetConfirmed = boolean(targetOffer.IsConfirmed), lastModifiedTime = number(data.LastModifiedTime),
            tradeConfirmTime = number(data.TradeConfirmTime), localTokens = number(localOffer.Tokens),
            targetTokens = number(targetOffer.Tokens), localOffer = items(localOffer), targetOffer = items(targetOffer)}
        summary.stage = "unverified"
        if summary.localConfirmed == true and summary.targetConfirmed == true then
            summary.stage = type(summary.tradeConfirmTime) == "number" and summary.tradeConfirmTime > 0
                and "confirmedCountdown" or "awaitingServerCompletion"
        elseif summary.localConfirmed == true and summary.targetConfirmed == false then summary.stage = "awaitingTargetConfirmation"
        elseif summary.targetConfirmed == true and summary.localConfirmed == false then summary.stage = "awaitingLocalConfirmation"
        elseif summary.playersReady == true then summary.stage = "awaitingConfirmation"
        elseif summary.localReady == true and summary.targetReady == false then summary.stage = "awaitingTargetReady"
        elseif summary.targetReady == true and summary.localReady == false then summary.stage = "awaitingLocalReady"
        elseif summary.localReady == false and summary.targetReady == false then summary.stage = "awaitingReady" end
        return summary
    end
    function M.tradeInventoryQuantities(inventory, catalog, slots)
        local quantities, wanted = {}, slots and {} or nil
        for _, slot in ipairs(slots or {}) do wanted[slot.sourceUUID] = true end
        for _, record in ipairs(M.normalize(inventory or {}, catalog, {CollectRecords = true,UUIDs=wanted}).items) do
            local uuid = M.uuid(record.UUID)
            if uuid then quantities[uuid] = record.Quantity end
        end
        return quantities
    end
    function M.tradeInventoryDelta(before, after)
        local result = {}
        for uuid, quantity in pairs(before or {}) do
            local change = (after and after[uuid] or 0) - quantity
            if change ~= 0 then table.insert(result, {uuid = uuid, delta = change}) end
        end
        for uuid, quantity in pairs(after or {}) do if not before or before[uuid] == nil then table.insert(result, {uuid = uuid, delta = quantity}) end end
        table.sort(result, function(a, b) return a.uuid < b.uuid end)
        return result -- A local delta alone never proves a completed trade or recipient ownership.
    end
    function M.equipmentEvents()
        return {profiles = {}, excludedIds = {}, accepted = 0, revision = 0, passiveUpdates = 0}
    end
    function M.observeEquipment(store, remote, args, options)
        if remote == "Added" then
            local batch = type(args[1]) == "table" and (type(args[1][1]) == "table" and args[1] or {args[1]}) or {}
            for _, serialized in ipairs(batch) do
                if serialized[1] ~= nil then
                    local owns, proof = M.profileScope(serialized[3], options.LocalUserId, serialized[2], serialized[4] == "All", options.PersonalChannels)
                    if owns then
                        local data = M.copyData(M.profileProjection(serialized[3]), options.MaxNodes)
                        if data then store.profiles[serialized[1]] = {data = data, verified = true, scopeReason = proof}; store.excludedIds[serialized[1]] = nil; store.accepted = store.accepted + 1; store.revision = (store.revision or 0) + 1 end
                    else store.excludedIds[serialized[1]] = true; store.profiles[serialized[1]] = nil end
                end
            end
            return
        end
        if remote == "Removed" then
            if store.profiles[args[1]] then store.revision = (store.revision or 0) + 1 end
            store.profiles[args[1]] = nil; return
        end
        if args[1] == nil or store.excludedIds[args[1]] then return end
        if M.isRemovedEquipmentPath(remote == "ArrayUpdate" and args[3] or args[2]) then return end
        local path = equipmentPath(remote == "ArrayUpdate" and args[3] or args[2])
        if not path then
            if remote == "Update" and args[3] == nil and type(args[2]) == "table" then
                for key, value in pairs(args[2]) do if equipmentPath({key}) then M.observeEquipment(store, "Set", {args[1], {key}, value}, options) end end
            end
            return
        end
        local profile = store.profiles[args[1]] or {data = {}, verified = false}
        if not store.profiles[args[1]] then
            local count = 0; for _ in pairs(store.profiles) do count = count + 1 end
            if count >= 16 then return end
        end
        if remote == "Set" then
            local value, err = M.copyData(M.equipmentEventValue(path, args[3]), options.MaxNodes); if err then return end
            if value == "\0" then value = false end
            setPath(profile.data, path, value)
        elseif remote == "Update" and type(args[3]) == "table" then
            local target = M.path(profile.data, path)
            if type(target) ~= "table" then target = {}; setPath(profile.data, path, target) end
            local value = M.copyData(M.equipmentEventValue(path, args[3]), options.MaxNodes); if not value then return end
            for key, child in pairs(value) do if child == "\0" then target[key] = false else target[key] = child end end
        elseif remote == "ArrayUpdate" then
            local array = M.path(profile.data, path)
            if type(array) ~= "table" then return end -- Unknown prior array positions must not be invented.
            if args[2] == "c" then setPath(profile.data, path, {})
            elseif args[2] == "i" then
                local index = args[5] or #array + 1
                if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #array + 1 then return end
                table.insert(array, index, M.copyData(args[4], options.MaxNodes))
            elseif args[2] == "r" then
                local index = args[4] or #array
                if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #array then return end
                table.remove(array, index)
            else return end
        else return end
        store.profiles[args[1]] = profile; store.accepted = store.accepted + 1
        if M.equipmentChangeRelevant(path, remote, args[3]) then
            store.revision = (store.revision or 0) + 1
        else store.passiveUpdates = (store.passiveUpdates or 0) + 1 end
    end
    -- GUI visibility is never evidence of removal. Keep an account-bound bag independently of widgets.
    function M.bagLedger(userId)
        return {userId = tonumber(userId), groups = {}, uuids = {}, collections = {}, unresolvedRemovals = 0,
            authoritativeCategories = {}, revision = 0, capturedAt = 0}
    end
    local function bagSignature(record, catalog)
        local entry = M.lookup(catalog, record.Id, record.Name, record.Type)
        local variants = M.itemVariants(record, catalog)
        return M.category(entry and entry.category or record.Type) .. "\0" .. tostring(entry and entry.id or record.Id or record.Name)
            .. "\0" .. variants.variant .. "\0" .. variants.status
    end
    function M.bagReindex(ledger, catalog)
        local groups, keys = {}, {}
        for oldKey, group in pairs(ledger.groups) do
            group.data.Type = M.category(group.data.Type)
            local signature = bagSignature(group.data, catalog)
            local weight = tonumber(group.data.Weight or metadata(group.data).Weight)
            local key = signature .. "\0" .. tostring(weight or "")
            keys[oldKey] = key; group.key = key; group.signature = signature
            if groups[key] then
                groups[key].count = math.max(groups[key].count, group.count)
                groups[key].deleted = math.max(groups[key].deleted, group.deleted)
            else groups[key] = group end
        end
        ledger.groups = groups
        for _, member in pairs(ledger.uuids) do member.key = keys[member.key] or member.key; member.data.Type = M.category(member.data.Type) end
        local claimed = {}
        for _, member in pairs(ledger.uuids) do if not member.deleted then claimed[member.key] = (claimed[member.key] or 0) + member.qty end end
        for key, quantity in pairs(claimed) do if groups[key] then groups[key].count = math.max(groups[key].count, quantity) end end
        local categories = {}
        for category in pairs(ledger.authoritativeCategories or {}) do categories[M.category(category)] = true end
        ledger.authoritativeCategories = categories
        for collection, known in pairs(ledger.collections) do
            local mapped = {}; for category in pairs(known) do mapped[M.category(category)] = true end
            ledger.collections[collection] = mapped
        end
    end
    local function indexBagWeight(index, group)
        local signature = group.signature
        local bucket = index[signature]
        if not bucket then bucket = {bins = {}, rounded = {}}; index[signature] = bucket end
        local weight = tonumber(group.data.Weight or metadata(group.data).Weight)
        local resolution = tonumber(metadata(group.data).WeightResolution) or 0
        if resolution > 0 then bucket.rounded[group.key] = group
        else
            local bin = weight and math.floor(weight * 1000000) or 'none'
            local values = bucket.bins[bin] or {}; bucket.bins[bin] = values; values[group.key] = group
        end
    end
    local function bagGroupIndex(ledger, checkpoint)
        if ledger.indexedGroups ~= ledger.groups then
            local index, weights = {}, {}
            for _, group in pairs(ledger.groups) do
                if checkpoint then checkpoint() end
                local bucket = index[group.signature] or {}; index[group.signature] = bucket
                bucket[group.key] = group
                indexBagWeight(weights, group)
            end
            ledger.groupIndex = index; ledger.weightIndex = weights; ledger.indexedGroups = ledger.groups
        end
        return ledger.groupIndex
    end
    local function bagGroup(ledger, record, catalog, checkpoint)
        local signature = bagSignature(record, catalog)
        local weight = tonumber(record.Weight or metadata(record).Weight)
        local key = signature .. "\0" .. tostring(weight or "")
        local match, matches = nil, 0
        local index = bagGroupIndex(ledger, checkpoint)
        local bucket = index[signature] or {}; index[signature] = bucket
        local weights = ledger.weightIndex[signature]
        local checked = {}
        local function inspect(candidates)
        if matches > 1 then return end
        for _, group in pairs(candidates or {}) do
            if checkpoint then checkpoint() end
            if checked[group] then continue end
            checked[group] = true
            local other = tonumber(group.data.Weight or metadata(group.data).Weight)
            local resolution = tonumber(metadata(group.data).WeightResolution) or 0
            if group.signature == signature and ((weight == nil and other == nil) or
                (weight and other and math.abs(weight - other) <= resolution / 2 + 0.000001)) then
                match = group; matches = matches + 1
                if matches > 1 then return end
            end
        end
        end
        if weights then
            if weight then
                local bin = math.floor(weight * 1000000)
                -- Keep the original epsilon and ambiguous-weight behavior, including bin boundaries.
                for offset = -2, 2 do inspect(weights.bins[bin + offset]) end
            else inspect(weights.bins.none) end
            inspect(weights.rounded)
        end
        if matches == 1 then return match end
        local group = ledger.groups[key]
        if not group then
            group = {key = key, signature = signature, data = M.copyData(record, nil, checkpoint), count = 0, deleted = 0}
            ledger.groups[key] = group; bucket[key] = group
            indexBagWeight(ledger.weightIndex, group)
        end
        return group
    end
    local function bagRecords(inventory, catalog)
        return M.normalize(inventory, catalog, {CollectRecords = true})
    end
    function M.bagMergeGui(ledger, records, catalog, userId, now, prepared, checkpoint)
        if ledger.userId ~= tonumber(userId) then return false, "UserId cache berbeda" end
        local counts, samples = {}, {}
        local flat = prepared or bagRecords({Items = records}, catalog)
        if flat.truncated then return false, "GUI payload terpotong" end
        for _, record in ipairs(flat.items) do
            if checkpoint then checkpoint() end
            if not ledger.fullSnapshot and not ledger.authoritativeCategories[record.Type] then
                local group = bagGroup(ledger, record, catalog, checkpoint)
                counts[group.key] = (counts[group.key] or 0) + record.Quantity; samples[group.key] = record
                local uid = M.uuid(record.UUID)
                if uid and not ledger.uuids[uid] then ledger.uuids[uid] = {key = group.key, data = record, qty = record.Quantity} end
            end
        end
        local changed = false
        for key, count in pairs(counts) do
            if checkpoint then checkpoint() end
            local group = ledger.groups[key]
            local quantity = math.max(group.count, count - group.deleted)
            if quantity ~= group.count then changed = true; group.count = quantity end
            -- Display enrichments (icons/mutations) do not change identity or imply deletion.
            local previous = group.data
            group.data = samples[key]
            -- Samples can change GUI weight precision; rebuild auxiliary indexes on the next merge.
            if tonumber(previous.Weight or metadata(previous).Weight) ~= tonumber(group.data.Weight or metadata(group.data).Weight)
                or tonumber(metadata(previous).WeightResolution) ~= tonumber(metadata(group.data).WeightResolution) then ledger.indexedGroups = nil end
        end
        if changed then ledger.revision = ledger.revision + 1; ledger.capturedAt = now or os.time() end
        return changed
    end
    function M.bagUpsert(ledger, record, catalog, inserted)
        local flat = bagRecords({Items = {record}}, catalog)
        local value = flat.items[1]; if not value then return false end
        local uid = M.uuid(value.UUID); if not uid then return false end
        local existing = ledger.uuids[uid]
        if existing and existing.deleted and not inserted then return false end
        local group = bagGroup(ledger, value, catalog)
        if existing and not existing.deleted then
            local old = ledger.groups[existing.key]
            if old then
                old.count = math.max(0, old.count - existing.qty)
                if old ~= group then old.deleted = old.deleted + existing.qty end
            end
            group.count = group.count + value.Quantity
        elseif inserted then
            group.count = group.count + value.Quantity
        else
            -- A UUID learned for an existing item replaces anonymous coverage, not an extra item.
            local claimed = 0
            for _, member in pairs(ledger.uuids) do if not member.deleted and member.key == group.key then claimed = claimed + member.qty end end
            group.count = math.max(group.count, claimed + value.Quantity)
        end
        ledger.uuids[uid] = {key = group.key, data = value, qty = value.Quantity}
        ledger.revision = ledger.revision + 1; ledger.capturedAt = os.time()
        return true
    end
    function M.bagRemove(ledger, uid)
        uid = M.uuid(uid); local member = uid and ledger.uuids[uid]
        if not member or member.deleted then return false end
        local group = ledger.groups[member.key]
        if group then
            group.count = math.max(0, group.count - member.qty); group.deleted = group.deleted + member.qty
        end
        member.deleted = true
        ledger.revision = ledger.revision + 1; ledger.capturedAt = os.time()
        return true
    end
    function M.bagInventory(ledger)
        local records, claimed = {}, {}
        for _, member in pairs(ledger.uuids) do
            if not member.deleted then
                table.insert(records, member.data); claimed[member.key] = (claimed[member.key] or 0) + member.qty
            end
        end
        for key, group in pairs(ledger.groups) do
            local anonymous = group.count - (claimed[key] or 0)
            if anonymous > 0 then
                local record = M.copyData(group.data); record.UUID = nil; record.Quantity = anonymous
                record.UUIDUnavailable = true; table.insert(records, record)
            end
        end
        return {Items = records}
    end
    function M.bagReplace(ledger, inventory, catalog, collection, prepared, checkpoint)
        local flat = prepared or bagRecords(inventory, catalog)
        if flat.truncated then return false end
        local categories = ledger.collections[collection] or {}
        for _, record in ipairs(flat.items) do if checkpoint then checkpoint() end; categories[record.Type] = true end
        if collection ~= "Inventory.Items" then
            local category = collection:match("^Inventory%.([^%.]+)$")
            if category then categories[M.category(category)] = true end
        end
        if collection == "Inventory" then
            ledger.groups = {}; ledger.uuids = {}; ledger.collections = {}; ledger.authoritativeCategories = {}; ledger.fullSnapshot = false
        end
        for category in pairs(categories) do ledger.authoritativeCategories[category] = nil end
        local removed = {}
        for key, group in pairs(ledger.groups) do
            if categories[group.data.Type] then ledger.groups[key] = nil; removed[key] = true end
        end
        for uid, member in pairs(ledger.uuids) do if removed[member.key] then ledger.uuids[uid] = nil end end
        ledger.indexedGroups = nil
        ledger.collections[collection] = categories
        M.bagMergeGui(ledger, flat.items, catalog, ledger.userId, nil, flat, checkpoint)
        for category in pairs(categories) do ledger.authoritativeCategories[category] = true end
        if collection == "Inventory" then ledger.fullSnapshot = true end
        ledger.revision = ledger.revision + 1; ledger.capturedAt = os.time()
        return true
    end
    function M.observeBag(store, ledger, remote, args, options, catalog)
        if tonumber(options.LocalUserId) ~= ledger.userId then return false end
        local path = protocolPath(remote == "ArrayUpdate" and args[3] or args[2])
        local before = store.records[args[1]]
        local oldItem, itemPath
        if path and before then
            for length = 1, #path do
                local prefix = {}; for index = 1, length do prefix[index] = path[index] end
                local value = M.path(before.data, prefix)
                if itemRecord(value) then oldItem = M.copyData(value); itemPath = prefix; break end
            end
            if remote == "ArrayUpdate" and args[2] == "r" then
                local array = M.path(before.data, path)
                local index = args[4] or ((before.complete or before.completePaths[pathName(path)]) and type(array) == "table" and #array)
                oldItem = type(array) == "table" and index and M.copyData(array[index]) or nil
            end
        end
        local changed = M.observe(store, remote, args, options)
        if not changed then return false end
        if remote == "Removed" then return true end -- Replication lifecycle is not sale/trade evidence.
        if remote ~= "Added" and ledger.channelId and ledger.channelId ~= args[1] then return true end
        local _, record = M.observedInventory(store)
        if not record then return true end
        if ledger.channelId and ledger.channelId ~= record.id then return true end
        ledger.channelId = record.id
        if record.complete then
            if options.DeferCompleteBag then ledger.pendingComplete = true
            else M.bagReplace(ledger, record.data.Inventory, catalog, "Inventory") end
            return true
        end
        if not path then return true end
        -- An established collection snapshot remains authoritative through nested updates/removals.
        for length = 1, math.min(2, #path) do
            local prefix = {}; for index = 1, length do prefix[index] = path[index] end
            local known = pathName(prefix)
            if record.completePaths[known] then
                local value = M.path(record.data, prefix)
                if type(value) == "table" then
                    M.bagReplace(ledger, length == 1 and value or {[prefix[2]] = value}, catalog, known)
                    return true
                end
            end
        end
        local label = pathName(path)
        if (remote == "Set" or (remote == "ArrayUpdate" and args[2] == "c")) and #path <= 2
            and record.completePaths[label] then
            local value = M.path(record.data, path)
            M.bagReplace(ledger, #path == 1 and value or {[path[2]] = value}, catalog, label)
        elseif remote == "ArrayUpdate" and args[2] == "i" then
            M.bagUpsert(ledger, args[4], catalog, true)
            local row = bagRecords({Items = {args[4]}}, catalog).items[1]
            if row then ledger.collections[label] = ledger.collections[label] or {}; ledger.collections[label][row.Type] = true end
        elseif remote == "ArrayUpdate" and args[2] == "r" then
            if not (oldItem and M.bagRemove(ledger, oldItem.UUID)) then ledger.unresolvedRemovals = ledger.unresolvedRemovals + 1 end
        elseif itemPath then
            local value = M.path(record.data, itemPath)
            if type(value) == "table" then M.bagUpsert(ledger, value, catalog, false)
            elseif oldItem then M.bagRemove(ledger, oldItem.UUID) end
        elseif remote == "Set" and M.uuid(path[#path]) then
            local value = M.path(record.data, path)
            if type(value) == "table" then
                value = M.copyData(value); value.UUID = value.UUID or path[#path]; M.bagUpsert(ledger, value, catalog, false)
            elseif not M.bagRemove(ledger, path[#path]) then ledger.unresolvedRemovals = ledger.unresolvedRemovals + 1 end
        end
        return true
    end
    -- Capture only stock, equipment/stat fields, and definitions. This copy never yields:
    -- later normalization may yield safely while live Replion tables keep changing.
    function M.captureGraph(value, limit)
        if type(value) ~= "table" then return value end
        local seen, pending, nodes, aliased = {}, {}, 0, false
        local function clone(source, depth)
            if seen[source] then aliased = true; return seen[source] end
            if depth > 24 then error("Snapshot terlalu dalam", 0) end
            local target = table.clone(source); seen[source] = target
            table.insert(pending, {source, target, depth})
            return target
        end
        local root = clone(value, 0)
        while #pending > 0 do
            local job = table.remove(pending)
            for key, child in next, job[1] do
                nodes += 1
                if nodes > (limit or 200000) then error("Snapshot melebihi batas capture", 0) end
                if type(child) == "table" then job[2][key] = clone(child, job[3] + 1) end
            end
        end
        return root, nodes, aliased
    end
    function M.profileProjection(data)
        if type(data) ~= "table" then return {} end
        local function project(root)
            local result = {}
            for _, field in ipairs({"UserId", "OwnerUserId", "PlayerUserId", "Abilities", "EquippedItems", "EquippedId", "EquippedType",
                "RodEnchantments", "FishingRodEnchantments", "EquippedRodEnchantments", "EquippedRodEnchants", "EquippedRodEnchant",
                "Coin", "Coins", "CoinBalance", "TotalFishCaught", "FishCaught", "TotalCaught", "RarestFishOdds", "RarestFishChanceDenominator", "RarestFish"}) do
                result[field] = root[field]
            end
            for _, config in pairs(equipmentSlots) do
                for _, field in ipairs(config.fields) do result[field] = root[field] end
            end
            if type(root.Inventory) == "table" then
                local equipment = {}
                for _, config in pairs(equipmentSlots) do
                    for _, field in ipairs(config.fields) do equipment[field] = root.Inventory[field] end
                end
                result.Inventory = equipment
            end
            for _, field in ipairs({"Equipment", "Equipped", "Loadout"}) do
                if type(root[field]) == "table" then
                    local container = table.clone(root[field])
                    container.Potion = nil; container.Potions = nil; container.EquippedPotions = nil
                    container.EquippedPotionUUID = nil; container.EquippedPotionId = nil
                    container.LastCoordinate = nil; container.LastCharacterCoordinate = nil; container.LastCharacterLocationName = nil
                    result[field] = container
                end
            end
            for _, field in ipairs({"Statistics", "Stats", "Wallet", "Currencies", "Currency"}) do
                if type(root[field]) == "table" then
                    local fields = {}
                    for _, key in ipairs({"Coins", "FishCaught", "TotalFishCaught", "RarestFishCaught", "RarestFishOdds", "RarestFishChanceDenominator", "RarestFish"}) do
                        fields[key] = root[field][key]
                    end
                    result[field] = fields
                end
            end
            if type(root.Analytics)=="table" then
                result.Analytics={}
                for _,key in ipairs({"LastSecretTimestamp","LastForgottenTimestamp","FishSinceLastSecret","FishSinceLastForgotten"}) do result.Analytics[key]=root.Analytics[key] end
            end
            return result
        end
        local result = project(data)
        for _, field in ipairs({"Data", "Profile"}) do if type(data[field]) == "table" then result[field] = project(data[field]) end end
        return result
    end
    function M.captureRead(inventory, profile, catalog, limit, definitions)
        local stock, nodes, aliased = M.captureGraph(inventory, limit)
        local projection = M.captureGraph(M.profileProjection(profile), limit)
        definitions = definitions or M.captureGraph(catalog, limit)
        return {inventory = stock, profile = projection, catalog = definitions, nodes = nodes, isolated = true, aliased=aliased}
    end
    function M.queueSourceChange(state, value)
        local path = sourcePath(value)
        if not path or #path == 0 then state.captureReset = true; return end
        local pending = state.captureChanges or {}; state.captureChanges = pending
        if #pending >= 256 then state.captureReset = true; table.clear(pending); return end
        table.insert(pending, path)
    end
    -- Copy changed branches from the current source at one non-yielding boundary.
    -- Parent replacement/array edits copy that collection; unknown paths force a full read.
    -- Old snapshots share only immutable branches, so an upload never sees half an update.
    function M.captureChanges(base, inventory, changes, channel, limit)
        local root, nodes = base, 0
        local function replace(old, live, path, at)
            if at > #path then
                local value, count = M.captureGraph(live, limit)
                nodes += count or 0
                if nodes > (limit or 200000) then error("Snapshot melebihi batas capture", 0) end
                return value
            end
            if type(old) ~= "table" or type(live) ~= "table" then return M.captureGraph(live, limit) end
            local nextRoot = table.clone(old)
            local key = path[at]
            nextRoot[key] = replace(old[key], live[key], path, at + 1)
            return nextRoot
        end
        for _, original in ipairs(changes) do
            local path = table.clone(original)
            if channel ~= "Inventory" and channel ~= "Backpack" then
                if path[1] == "Data" or path[1] == "Profile" then table.remove(path, 1) end
                if #path == 0 or path[1] == "Abilities" then return M.captureGraph(inventory, limit) end
                if path[1] == "Inventory" then table.remove(path, 1)
                else continue end -- Equipment is captured separately from stock.
            end
            -- A replaced table may introduce sharing with another record. Capture
            -- the full tree once to detect aliases instead of assuming independence.
            if type(M.path(inventory,path)) == "table" then return M.captureGraph(inventory,limit) end
            root = replace(root, inventory, path, 1)
        end
        return root, nodes
    end
    function M.equipmentEventValue(path, value)
        local key = path[#path]
        if type(value) == "table" and (key == "Equipment" or key == "Equipped" or key == "Loadout") then
            return M.profileProjection({[key] = value})[key]
        end
        return value
    end
    function M.isRemovedEquipmentPath(value)
        local path = sourcePath(value)
        if not path then return false end
        if path[1] == "Data" or path[1] == "Profile" then table.remove(path, 1) end
        if path[1] == "Inventory" then
            return path[2] == "EquippedPotions" or path[2] == "EquippedPotionUUID" or path[2] == "EquippedPotionId"
        end
        local container = path[1] == "Equipment" or path[1] == "Equipped" or path[1] == "Loadout"
        if container then table.remove(path, 1) end
        return path[1] == "EquippedPotions" or path[1] == "EquippedPotionUUID" or path[1] == "EquippedPotionId"
            or container and (path[1] == "Potion" or path[1] == "Potions")
    end

    return M
end)()

-- The Luau CLI can require this file to exercise normalization without Roblox.
if not game then return Core end

local CONFIG = {
    RefreshSeconds = 60, -- Event listeners still refresh changed inventory after 0.15–0.3 seconds.
    PageSize = 25,
    ReplionChannels = { "Data", "PlayerData", "Profile", "Inventory", "Backpack" },
    -- The supplied scanner trace confirms ArrayUpdate on Inventory.Items.
    -- Read its parent too so rods/baits/other sibling collections remain included.
    InventoryPaths = { { "Inventory" }, { "Data", "Inventory" }, { "Profile", "Inventory" }, { "Inventory", "Items" } },
    ItemPath = { "Items" },
    ReplionPackage = "ytrev_replion@2.0.0-rc.3",
    ObserveInventoryEvents = true,
    ReadInventoryGui = true, -- Automatic retained-widget fallback at the user-confirmed native bag path.
    AutoInventoryGuiPaths = {{"Inventory", "Main", "Content", "Pages", "Inventory2", "Main", "Inventory"}},
    MaxGuiInstances = 40000,
    CatalogPaths = Core.catalogPaths(),
    TierPaths = { { "Tiers" }, { "Modules", "Tiers" } },
    VariantPaths = { { "Mutations" }, { "Variants" }, { "Modules", "Mutations" }, { "Modules", "Variants" },
        { "Shared", "Mutations" } },
    EnchantPaths = {{"Enchantments"}, {"Enchants"}, {"Modules", "Enchantments"}, {"Modules", "Enchants"}},
    CatalogWorkers = 1, -- One native lookup/module at a time; deterministic merge and 2ms checkpoints.
    RequireTimeout = 1,
    ReplionRequireTimeout = 5,
    MaxInventoryNodes = 200000,
    -- Optional function returning inventoryTable, sourceLabel. It must only read local data.
    InventoryReader = nil,
}

local env = (type(getgenv) == "function" and getgenv()) or _G
-- Stop any recorder left by a previous execute. A fresh client session is still
-- needed to remove a previously installed executor hook completely.
if type(env.RENN_EQUIP_CAPTURE) == "table" then env.RENN_EQUIP_CAPTURE.listener = nil end
local previous = env.RENN_STATS
local legacy = env.RENN_INVENTORY
if type(legacy) == "table" and type(legacy.Close) == "function" then pcall(legacy.Close) end
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
while not player do task.wait(); player = Players.LocalPlayer end
local playerGui = player:WaitForChild("PlayerGui")
local reuse = type(previous) == "table" and type(previous.bag) == "table" and previous.bag.userId == player.UserId
    and previous.playerGui == playerGui and type(previous.bag.authoritativeCategories) == "table"
if type(previous) == "table" and type(previous.Close) == "function" then pcall(previous.Close) end
local state = {
    alive = true, paused = false, busy = false, queued = false, catalog = Core.catalog(),
    catalogReady = false, catalogFailures = 0, catalogPhase = "Menunggu discovery client", catalogModules = 0,
    catalogLabelFailures = 0, connections = {}, tasks = {}, sourceConnections = {},
    replion = nil, client = nil, clients = {}, discoveryNotes = {}, rows = {}, changes = {}, baselineSource = nil, snapshot = nil,
    source = "Menunggu data", category = "Semua", order = "Nama", page = 1, query = "", renderRevision = 0,
    observed = Core.eventStore(), equipmentObserved = Core.equipmentEvents(), remoteCount = 0, partial = true,
    cacheReaderProbes = {},
    bag = Core.bagLedger(player.UserId),
    playerGui = playerGui, revision = 0, statsRevision = 0, collectorVersion = "1.9",
}
if reuse then
    state.bag = previous.bag; Core.bagReindex(state.bag, state.catalog)
    state.observed = previous.observed or state.observed
    state.equipmentObserved = previous.equipmentObserved or state.equipmentObserved
    state.reusedCache = true
end

local function connect(signal, callback, bucket)
    local connection = signal:Connect(callback)
    table.insert(bucket or state.connections, connection)
    return connection
end
local function spawnTask(callback)
    local thread = task.defer(function()
        local running = coroutine.running()
        state.tasks[running] = true
        local ok, err = pcall(callback)
        state.tasks[running] = nil
        if not ok and state.alive then state.lastError = tostring(err) end
    end)
    state.tasks[thread] = true
    return thread
end
local function boundedRequire(module, loader, timeout)
    local done, ok, result = false, false, nil
    local thread = spawnTask(function()
        ok, result = pcall(loader or require, module)
        done = true
    end)
    local deadline = os.clock() + (timeout or CONFIG.RequireTimeout)
    while state.alive and not done and os.clock() < deadline do task.wait() end
    if not done then
        pcall(task.cancel, thread)
        state.tasks[thread] = nil
        return false, "Module timeout: " .. module.Name
    end
    return ok, result
end
local function instancePath(path)
    local current = ReplicatedStorage
    for _, name in ipairs(path) do
        current = current and current:FindFirstChild(name)
    end
    return current
end
local refresh, render, status, refreshCategories, discoverClient
local function workCheckpoint()
    if state.sharedCheckpoint then return state.sharedCheckpoint end
    state.sharedCheckpoint = Core.workCheckpoint(function()
        task.wait()
        if not state.alive then error("Collector ditutup") end
    end, os.clock, 0.002)
    return state.sharedCheckpoint
end
local function invalidateRead()
    state.inputGeneration = (state.inputGeneration or 0) + 1
    if state.busy then state.pendingRefresh = true end
end
state.GetDiagnostics = function()
    if state.equipmentDiagnosticReader then state.equipmentDiagnosticReader() end
    if state.diagnosticsReader then state.diagnostics = state.diagnosticsReader() end
    return (state.diagnostics or "Menunggu penemuan data") .. (state.lastError and ("\nLast error: " .. state.lastError) or "")
        .. "\n" .. Core.catalogDiagnostics(state, os.clock())
end

-- Headless: status lives in memory and is delivered to the authenticated website.
status = function(message) state.status = tostring(message) end
render = function() end
refreshCategories = function() end
state.renderInfo = function() end
state.renderLoading = function() end
state.renderEquipment = function() end
state.RestorePanel = function() end
state.HideForTradeRecording = function() end
state.SetRecorderControls = function() end

state.Close = function()
    if not state.alive then return end
    if state.StopAutoTrade then pcall(state.StopAutoTrade, "Collector ditutup") end
    state.alive = false

    local running = coroutine.running()
    for thread in pairs(state.tasks) do if thread ~= running then pcall(task.cancel, thread) end end
    for _, bucket in ipairs({ state.connections, state.sourceConnections, state.tradeConnections or {} }) do
        for _, connection in ipairs(bucket) do pcall(function() connection:Disconnect() end) end
        table.clear(bucket)
    end
    if state.clearViewConnections then state.clearViewConnections() end
    if state.closePicker then state.closePicker() end
    if state.gui then state.gui:Destroy() end
    if state.recorderGui then state.recorderGui:Destroy() end
    if env.RENN_STATS == state then env.RENN_STATS = nil end
end
env.RENN_STATS = state

-- Reader and catalog discovery are below the GUI to keep initial loading visible.
local function describeShape(value)
    if type(value) ~= "table" then return type(value) end
    local keys = {}
    for key, child in pairs(value) do
        if #keys >= 24 then table.insert(keys, "..."); break end
        table.insert(keys, tostring(key) .. ":" .. type(child))
    end
    table.sort(keys)
    return "{" .. table.concat(keys, ", ") .. "}"
end
local function guiScope(node, selected, confirmed)
    if not node or not node:IsA("ScrollingFrame") then return false, "Area tas harus ScrollingFrame" end
    local localGui = node:IsDescendantOf(playerGui)
    local visible, blocked, cursor, hiddenPath = true, false, node, nil
    while cursor and cursor ~= playerGui do
        if cursor == state.gui or cursor.Name == "RennInventoryScanner" then blocked = true end
        if (cursor:IsA("GuiObject") and not cursor.Visible) or (cursor:IsA("ScreenGui") and not cursor.Enabled) then
            visible = false; hiddenPath = hiddenPath or cursor:GetFullName()
        end
        if Core.blockedGuiName(cursor.Name) then blocked = true end
        cursor = cursor.Parent
    end
    local allowed, reason = Core.guiScope({ localPlayerGui = localGui, selectedList = selected, visible = visible,
        blocked = blocked, confirmedList = confirmed })
    return allowed, reason, hiddenPath
end
state.SelectInventoryGui = function(node)
    local ok, reason = guiScope(node, true)
    if not ok then return false, reason end
    state.guiInventoryRoot = node
    state.confirmedGuiRoot = node
    state.guiSelectionSource = "Klik pengguna"
    local cursor = node
    while cursor and cursor ~= playerGui do
        if cursor:IsA("ScreenGui") and (cursor.Name:lower() == "inventory" or cursor.Name:lower() == "backpack") then
            state.guiBagRoot = cursor; break
        end
        cursor = cursor.Parent
    end
    return true, "Daftar tas dipilih: " .. node:GetFullName()
end
state.findAutomaticInventoryGui = function()
    if state.guiInventoryRoot and state.guiInventoryRoot:IsDescendantOf(playerGui) then return end
    for _, path in ipairs(CONFIG.AutoInventoryGuiPaths) do
        local node = playerGui
        for _, name in ipairs(path) do node = node and node:FindFirstChild(name) end
        if node and node:IsA("ScrollingFrame") and guiScope(node, true, true) then
            state.guiInventoryRoot = node; state.confirmedGuiRoot = node
            state.guiBagRoot = playerGui:FindFirstChild(path[1])
            state.guiSelectionSource = "Otomatis: path Inventory akun lokal yang terkonfirmasi dari log"
            return
        end
    end
end
state.PickInventoryAtPosition = function(x, y)
    local ok, hits = pcall(playerGui.GetGuiObjectsAtPosition, playerGui, x, y)
    if not ok then return false, "Pembacaan posisi GUI gagal: " .. tostring(hits) end
    for _, hit in ipairs(hits) do
        local scrolling, reason = Core.guiHitList(hit, playerGui, state.gui)
        if reason then return false, reason end
        if scrolling then
            local accepted, message = state.SelectInventoryGui(scrolling)
            if accepted then state.clickedGuiPath = hit:GetFullName(); state.pickError = nil end
            return accepted, message
        end
    end
    return false, "Belum menemukan daftar di bawah kartu yang diklik"
end
state.readGui = function()
    if not CONFIG.ReadInventoryGui then return nil end
    state.findAutomaticInventoryGui()
    local selected = state.guiInventoryRoot
    local allowed, reason, hiddenPath = guiScope(selected, selected ~= nil, selected ~= nil and state.confirmedGuiRoot == selected)
    if not allowed then
        state.guiDiagnostics = "Widget tas otomatis belum tersedia: " .. tostring(reason)
            .. ". Snapshot client/event masih dicari; widget yang belum dibuat tidak membuktikan tas kosong."
        return nil
    end
    local buckets, visited, uuidCards, imageCount, factCount, stopped, samples = {}, 0, 0, 0, 0, false, {}
    local currentList = selected
    state.guiIds = state.guiIds or setmetatable({}, { __mode = "k" })
    local function identity(node)
        if not state.guiIds[node] then state.guiIdCounter = (state.guiIdCounter or 0) + 1; state.guiIds[node] = state.guiIdCounter end
        return state.guiIds[node]
    end
    local function inList(node)
        return Core.guiItemScope(node, currentList)
    end
    local function factsFor(card, uid, anonymous)
        local ok, attributes = pcall(card.GetAttributes, card)
        local facts = { name = uid or card.Name, attributes = ok and attributes or {}, labels = {}, images = {},
            allowAnonymous = anonymous, path = card:GetFullName() }
        local stack, inspected = { card }, 0
        while #stack > 0 and inspected < 100 do
            local child = table.remove(stack); inspected = inspected + 1; factCount = factCount + 1
            if child:IsA("TextLabel") or child:IsA("TextButton") then table.insert(facts.labels, {name = child.Name, text = child.Text}) end
            if child:IsA("ImageLabel") or child:IsA("ImageButton") then table.insert(facts.images, {name = child.Name, image = child.Image}) end
            for _, nested in ipairs(child:GetChildren()) do table.insert(stack, nested) end
        end
        facts.truncated = #stack > 0
        return facts
    end
    local function addCard(bucket, card, uid, anonymous)
        if bucket.checked[card] then return end
        bucket.checked[card] = true
        if factCount >= 100000 then stopped = true; return end
        local record = Core.guiRecord(factsFor(card, uid, anonymous), state.catalog)
        if record then
            local parents, cursor = {}, card.Parent
            while cursor and cursor ~= playerGui do table.insert(parents, identity(cursor)); cursor = cursor.Parent end
            record.GuiCardId = identity(card) -- Local widget identity, never an invented item UUID.
            table.insert(bucket.cards, { id = identity(card), ancestors = parents, record = record })
        end
    end
    local roots, seenRoots = {selected}, {[selected] = true}
    if state.guiBagRoot and state.guiBagRoot:IsDescendantOf(playerGui) then
        local stack = {state.guiBagRoot}
        local checked = 0
        while #stack > 0 and checked < CONFIG.MaxGuiInstances do
            local node = table.remove(stack); checked = checked + 1
            if node:IsA("ScrollingFrame") and not seenRoots[node] then
                local allowedList = guiScope(node, true, true)
                local name = node.Name:lower()
                if allowedList and (name:find("inventory", 1, true) or name:find("list", 1, true)
                    or name:find("fish", 1, true) or name:find("rod", 1, true) or name:find("bait", 1, true)
                    or name:find("item", 1, true) or name:find("charm", 1, true) or name:find("pet", 1, true)
                    or name:find("emote", 1, true) or name:find("abilit", 1, true)) then
                    seenRoots[node] = true; table.insert(roots, node)
                end
            end
            for _, child in ipairs(node:GetChildren()) do table.insert(stack, child) end
        end
    end
    for _, root in ipairs(roots) do
        currentList = root
        if root ~= state.gui and root.Name ~= "RennInventoryScanner" then
            local bucket = { root = root, cards = {}, checked = {}, images = {}, quotas = {}, named = true, capacity = false }
            local stack = { root }
            while #stack > 0 do
                local node = table.remove(stack)
                visited = visited + 1
                if visited > CONFIG.MaxGuiInstances then stopped = true; break end
                local lower = node.Name:lower()
                if lower:find("inventory", 1, true) or lower:find("backpack", 1, true) then bucket.named = true end
                if node:IsA("TextLabel") or node:IsA("TextButton") then
                    local owned, maximum = node.Text:gsub("<[^>]*>", ""):match("([%d,]+)%s*/%s*([%d,]+)")
                    if owned and maximum then
                        bucket.capacity = true
                        table.insert(bucket.quotas, node:GetFullName() .. "=" .. owned .. "/" .. maximum)
                    end
                end
                local card = node:IsA("GuiObject") and node or nil
                local valueUUID
                if node:IsA("StringValue") and Core.uuid(node.Value) and node.Parent and node.Parent:IsA("GuiObject") then
                    card = node.Parent; valueUUID = Core.uuid(node.Value)
                end
                if card then
                    local ok, attributes = pcall(card.GetAttributes, card)
                    attributes = ok and attributes or {}
                    local uid = valueUUID or Core.uuid(card.Name) or Core.uuid(Core.first(attributes, { "UUID", "Uuid", "uuid", "Uid", "UniqueId", "ItemUUID" }))
                    if uid then
                        uuidCards = uuidCards + 1
                        if inList(card) then addCard(bucket, card, uid, false) end
                    end
                end
                if (node:IsA("ImageLabel") or node:IsA("ImageButton")) and Core.icon(node.Image) ~= "" and inList(node) then
                    imageCount = imageCount + 1; table.insert(bucket.images, node)
                end
                for _, child in ipairs(node:GetChildren()) do table.insert(stack, child) end
                if visited % 300 == 0 then task.wait(); if not state.alive then return nil end end
            end
            if bucket.named or bucket.capacity then
                for index, image in ipairs(bucket.images) do
                    local cursor = image
                    for _ = 1, 7 do
                        if not cursor or cursor:IsA("ScrollingFrame") or not cursor:IsA("GuiObject") then break end
                        if #samples < 5 and cursor == image.Parent then
                            local facts = factsFor(cursor, nil, true)
                            local text = {}; for _, label in ipairs(facts.labels) do table.insert(text, label.name .. "=" .. label.text:gsub("\n", "/"):sub(1, 100)) end
                            table.insert(samples, "GUI sample: " .. facts.path .. " | " .. table.concat(text, "; "):sub(1, 450))
                        end
                        addCard(bucket, cursor, nil, true); cursor = cursor.Parent
                        if stopped then break end
                    end
                    if index % 20 == 0 then task.wait(); if not state.alive then return nil end end
                    if stopped then break end
                end
            end
            table.insert(buckets, bucket)
            if stopped then break end
        end
    end
    local candidates, notes = {}, {}
    for _, bucket in ipairs(buckets) do
        local count = #Core.guiCards(bucket.cards)
        if bucket.named or bucket.capacity then
            for _, candidate in ipairs(bucket.cards) do table.insert(candidates, candidate) end
            table.insert(notes, bucket.root:GetFullName() .. ": " .. tostring(count) .. " kartu item")
            for index, quota in ipairs(bucket.quotas) do if index <= 8 then table.insert(notes, quota) end end
        end
    end
    for _, sample in ipairs(samples) do table.insert(notes, sample) end
    local records = Core.guiCards(candidates)
    -- Revalidate after traversal yields; changing the selected list must never mix two areas.
    if state.guiInventoryRoot ~= selected then return nil end
    local stillAllowed, finalReason, finalHiddenPath = guiScope(selected, true, state.confirmedGuiRoot == selected)
    if not stillAllowed then
        state.guiDiagnostics = "Area tas berubah saat dibaca: " .. tostring(finalReason)
        return nil
    end
    hiddenPath = finalHiddenPath or hiddenPath
    local noUUID = 0; for _, record in ipairs(records) do if not record.UUID then noUUID = noUUID + 1 end end
    if not state.catalogReady then
        state.guiDiagnostics = "Daftar tas terpilih; tunggu pemetaan katalog selesai sebelum mengunci item."
        return Core.bagInventory(state.bag), "Tas akun lokal: cache inventory (GUI + event; parsial)"
    end
    local changed = Core.bagMergeGui(state.bag, records, state.catalog, player.UserId, os.time())
    local inventory = Core.bagInventory(state.bag)
    local flat = Core.normalize(inventory, state.catalog)
    state.guiReadMetadata = {capturedAt = state.bag.capturedAt > 0 and state.bag.capturedAt or os.time(),
        cached = not changed, retainedWidgets = hiddenPath ~= nil}
    state.guiDiagnostics = "Visibilitas tas: " .. (hiddenPath and ("tertutup/tersembunyi pada " .. hiddenPath) or "terbuka")
        .. "\nGUI diperiksa: " .. tostring(visited) .. "; kandidat kartu UUID: " .. tostring(uuidCards)
        .. "; gambar dalam daftar: " .. tostring(imageCount) .. "; field GUI: " .. tostring(factCount)
        .. "; record cocok katalog/attribute: " .. tostring(#records) .. (stopped and " [BATAS TERCAPAI]" or "")
        .. "\nUUID asli tidak tersedia pada " .. tostring(noUUID) .. " kartu.\n" .. table.concat(notes, "\n")
    local categories = {}; for _, row in ipairs(flat.rows) do categories[row.category] = true end
    local names = {}; for category in pairs(categories) do table.insert(names, category) end; table.sort(names)
    state.guiDiagnostics = state.guiDiagnostics .. "\nCache akun: " .. tostring(state.bag.userId) .. "; jenis: " .. table.concat(names, ", ")
        .. "\nDaftar tas diperiksa: " .. tostring(#roots) .. "; record tersimpan: " .. tostring(flat.total)
        .. "; remove tanpa identitas pasti: " .. tostring(state.bag.unresolvedRemovals)
        .. "\nSearch/hidden/tab tidak menghapus cache. Penghapusan membutuhkan UUID/event atau snapshot inventory."
    if #records == 0 then
        state.guiDiagnostics = state.guiDiagnostics .. "\nBelum ada kartu dikenali; ini tidak membuktikan tas kosong. Buka tas dan kosongkan pencarian."
    end
    -- An explicitly chosen list remains the source even at zero cards; Tools are not this bag.
    return inventory, "Tas akun lokal: cache inventory (GUI + event; parsial)"
end
local function getInventory(replion)
    if type(replion) ~= "table" or replion.Destroyed then return nil end
    local data = replion.Data
    local inventory, path = Core.inventory(data, CONFIG.InventoryPaths)
    if inventory then return inventory, path, data end
    if type(replion.Get) == "function" then
        for _, candidate in ipairs(CONFIG.InventoryPaths) do
            local ok, value = pcall(replion.Get, replion, candidate)
            if ok and type(value) == "table" then return value, table.concat(candidate, "."), data end
        end
    end
    if (replion._channel == "Inventory" or replion._channel == "Backpack") and type(data) == "table" then
        return data, "<root>", data
    end
    return nil, nil, data
end
local function clearSourceConnections()
    for _, connection in ipairs(state.sourceConnections) do pcall(function() connection:Disconnect() end) end
    table.clear(state.sourceConnections)
end
local function bindSource(replion)
    if state.replion == replion then return end
    clearSourceConnections()
    state.replion = replion
    state.captureReset = true
    state.captureSubscribed = false
    local function changed(_, path)
        if not state.alive then return end
        if not Core.sourceChangeRelevant(path, CONFIG.InventoryPaths, replion._channel) then
            state.sourcePassiveUpdates = (state.sourcePassiveUpdates or 0) + 1
            return
        end
        state.sourceRelevantUpdates = (state.sourceRelevantUpdates or 0) + 1
        Core.queueSourceChange(state, path)
        invalidateRead()
        if state.paused or state.queued then return end
        state.queued = true
        spawnTask(function()
            task.wait(0.3); state.queued = false
            if state.alive and not state.paused then refresh() end
        end)
    end
    if type(replion.OnDataChange) == "function" then
        local ok, connection = pcall(replion.OnDataChange, replion, changed)
        if ok and connection then state.captureSubscribed = true; table.insert(state.sourceConnections, connection) end
    elseif type(replion.OnChange) == "function" then
        for _, candidate in ipairs(CONFIG.InventoryPaths) do
            local ok, connection = pcall(replion.OnChange, replion, candidate, function() changed() end)
            if ok and connection then table.insert(state.sourceConnections, connection) end
        end
    end
    if type(replion.BeforeDestroy) == "function" then
        local ok, connection = pcall(replion.BeforeDestroy, replion, function()
            state.captureReset = true; invalidateRead(); clearSourceConnections(); state.replion = nil
        end)
        if ok and connection then table.insert(state.sourceConnections, connection) end
    end
end
local function readSource()
    state.activeReader = nil; state.observedWarning = nil; state.ownerNotes = {}
    state.abilityAdditions = 0
    state.profileData = nil; state.profileId = nil; state.equipmentProfileData = nil
    if type(CONFIG.InventoryReader) == "function" then
        local value, name = CONFIG.InventoryReader()
        if type(value) ~= "table" then return nil, "InventoryReader belum mengembalikan tabel" end
        return value, name or "Custom reader", false
    end
    if state.replion and not state.replion.Destroyed then
        local inventory, path, data = getInventory(state.replion)
        if inventory and Core.profileScope(data, player.UserId, state.replion._channel or "Data",
            state.replion.ReplicateTo == "All", CONFIG.ReplionChannels) then
            state.stockPath = path
            state.activeReader = state.pinnedReader
            state.profileData = data; state.profileId = state.replion._id or state.bag.channelId
            inventory, state.abilityAdditions = Core.withProfileAbilities(inventory, data, player.UserId, state.catalog, state.readCache)
            state.readCache.replaceBag = true
            return inventory, "Replion " .. tostring(state.replion._channel or "Data") .. "." .. path, false
        end
    end
    state.nextSourceDiscovery = os.clock() + 30
    state.liveCandidates = 0; state.clientProbeNotes = {}
    for _, entry in ipairs(state.clients) do
        local client = entry.client
        local channels = table.clone(CONFIG.ReplionChannels)
        -- Current Replion caches also accept replication IDs. Inventory events identify the relevant one.
        for id in pairs(state.observed.records) do table.insert(channels, id) end
        local readers = Core.cacheReaders({env.debug or false, debug or false}, {
            getupvalues = env.getupvalues or getupvalues, getupvalue = env.getupvalue or getupvalue,
        })
        local names = {}; for _, reader in ipairs(readers) do table.insert(names, reader.name) end
        state.cacheCapability = #names > 0 and table.concat(names, ", ") or "Tidak tersedia"
        for _, reader in ipairs(readers) do
            local selfTest = state.cacheReaderProbes[reader.source]
            if not selfTest then selfTest = Core.probeCacheReader(reader); state.cacheReaderProbes[reader.source] = selfTest end
            table.insert(state.clientProbeNotes, "Uji API " .. reader.name .. ": " .. selfTest.status .. " | " .. selfTest.reason)
        end
        local candidates, probe = Core.clientCandidates(client, channels, readers)
        table.insert(state.clientProbeNotes, "Probe client: " .. entry.label .. " | lookup: " .. probe.lookups
            .. "; nil: " .. probe.emptyLookups .. "; error: " .. probe.lookupErrors)
        table.insert(state.clientProbeNotes, "Lookup error terakhir: " .. tostring(probe.lastLookupError or "Tidak ada"))
        table.insert(state.clientProbeNotes, "Pembacaan cache: " .. probe.cacheReads .. "; tabel terbaca: " .. probe.cacheTables
            .. "; replion ditemukan: " .. probe.cacheCandidates .. "; error: " .. probe.cacheErrors)
        for _, note in ipairs(probe.cacheNotes) do table.insert(state.clientProbeNotes, "Cache API " .. note) end
        local seen = {}; for _, candidate in ipairs(candidates) do seen[candidate.value] = true end
        for replion in pairs(entry.added or {}) do
            if not replion.Destroyed and not seen[replion] then table.insert(candidates, {value = replion, origin = "OnReplionAdded"}) end
        end
        state.liveCandidates = state.liveCandidates + #candidates
        for _, candidate in ipairs(candidates) do
            local replion = candidate.value
            if replion then
                local inventory, path, data = getInventory(replion)
                local label = replion._channel or candidate.origin
                state.dataShape = "Channel " .. tostring(label) .. ": " .. describeShape(data)
                local owns, proof = Core.profileScope(data, player.UserId, label, replion.ReplicateTo == "All", CONFIG.ReplionChannels)
                table.insert(state.ownerNotes, "Scope " .. tostring(label) .. ": " .. tostring(owns) .. " | " .. proof)
                if owns and not inventory and type(data) == "table" then state.equipmentProfileData = data end
                if inventory and owns then
                    bindSource(replion); state.stockPath = path
                    state.activeReader = entry.label; state.pinnedReader = entry.label
                    state.profileData = data; state.profileId = replion._id or state.bag.channelId
                    inventory, state.abilityAdditions = Core.withProfileAbilities(inventory, data, player.UserId, state.catalog, state.readCache)
                    state.readCache.replaceBag = true
                    return inventory, "Replion " .. tostring(label) .. "." .. path, false
                end
            end
        end
    end
    local observed, record = Core.observedInventory(state.observed)
    if record then state.profileId = record.id end
    if observed and not record.complete and state.catalogReady and state.bag.seedSequence ~= record.sequence then
        if not state.bag.channelId or state.bag.channelId == record.id then
            state.bag.channelId = record.id
            local flat = Core.normalize(observed, state.catalog, {CollectRecords = true})
            if not flat.truncated then
                for _, item in ipairs(flat.items) do Core.bagUpsert(state.bag, item, state.catalog, false) end
                state.bag.seedSequence = record.sequence
            end
        end
    end
    if state.readGui and (not record or not record.complete) then
        local guiInventory, label = state.readGui()
        if guiInventory then return guiInventory, label, true, state.guiReadMetadata end
    end
    if observed then
        clearSourceConnections(); state.replion = nil
        state.dataShape = "Protocol Inventory.Items | channel: " .. tostring(record.channel or "ID dari event")
        state.observedWarning = record.warning
        if record.complete then
            state.readCache.replaceBag = true
            local equipProfile = state.equipmentObserved.profiles[record.id]
            if equipProfile then
                observed, state.abilityAdditions = Core.withProfileAbilities(observed, equipProfile.data, player.UserId, state.catalog)
            end
            return observed, "Replion events: Inventory (snapshot penuh)", false,
                {capturedAt = record.capturedAt or (state.bag.capturedAt > 0 and state.bag.capturedAt) or os.time(), cached = true}
        end
        return Core.bagInventory(state.bag), "Tas akun lokal: cache inventory (GUI + event; parsial)", true,
            {capturedAt = state.bag.capturedAt > 0 and state.bag.capturedAt or os.time(), cached = true}
    end
    -- Losing/recreating a GUI or a Replion instance is not inventory deletion evidence.
    if state.bag.revision > 0 then
        return Core.bagInventory(state.bag), "Tas akun lokal: cache inventory (GUI + event; parsial)", true,
            {capturedAt = state.bag.capturedAt, cached = true}
    end
    -- Fallback is explicitly partial and never added to Replion counts (avoids duplicate tools).
    local tools, seen = {}, {}
    for _, container in ipairs({ player:FindFirstChildOfClass("Backpack") or false, player.Character or false }) do
        if container then
            for _, tool in ipairs(container:GetChildren()) do
                if tool:IsA("Tool") and not seen[tool] then
                    seen[tool] = true
                    local attributes = tool:GetAttributes()
                    table.insert(tools, {
                        Name = tool.Name, Id = attributes.ItemId or attributes.Id,
                        Type = attributes.ItemType or attributes.Type or "Tools",
                        Icon = tool.TextureId, Quantity = attributes.Quantity or attributes.Amount or 1,
                        Metadata = { Variant = attributes.Mutation, Weight = attributes.Weight },
                    })
                end
            end
        end
    end
    return { Tools = tools }, "Backpack + Character (parsial)", true
end
local function readEquipment(inventory, equipmentCache)
    local sources = {}; equipmentCache = equipmentCache or {}
    local catalog = equipmentCache.catalog or state.catalog
    if state.profileData then table.insert(sources, {data = state.profileData, name = "Replion profile"}) end
    if state.equipmentProfileData then table.insert(sources, {data = state.equipmentProfileData, name = "Replion equipment profile"}) end
    local eventProfile = state.profileId and state.equipmentObserved.profiles[state.profileId]
    if not eventProfile then
        local matched, count
        count = 0
        for _, profile in pairs(state.equipmentObserved.profiles) do
            if profile.verified then matched = profile; count = count + 1 end
        end
        if count == 1 then eventProfile = matched end
    end
    if eventProfile then table.insert(sources, {data = eventProfile.data, name = "Replion equipment events"}) end
    local attributes = player:GetAttributes()
    table.insert(sources, {data = attributes, name = "LocalPlayer attributes"})
    local held = {}
    if player.Character then
        for _, tool in ipairs(player.Character:GetChildren()) do
            if tool:IsA("Tool") then
                local record = tool:GetAttributes()
                record.Id = record.ItemId or record.Id
                record.UUID = record.UUID or record.ItemUUID or record.UniqueId
                record.Name = record.ItemName or tool.Name
                local entry = Core.lookup(catalog, record.Id, record.Name, "Fishing Rods")
                local actualType = record.ItemType or record.Type
                if entry or (actualType and Core.category(actualType) == "Fishing Rods") then
                    table.insert(held, record)
                end
            end
        end
    end
    if #held == 1 then table.insert(sources, {data = {EquippedRod = held[1]}, name = "Local Character.Tool"}) end
    local equipment = Core.equipment({}, inventory, catalog, player.UserId, equipmentCache)
    local stats = Core.playerStats({}, player.UserId, false)
    for _, source in ipairs(sources) do
        local incoming = Core.equipment(source.data, inventory, catalog, player.UserId, equipmentCache)
        local incomingStats = Core.playerStats(source.data, player.UserId, false)
        for _, key in ipairs({"coins", "caught", "rarestFish"}) do
            if stats[key].status == "unknown" and incomingStats[key].status == "known" then
                stats[key] = incomingStats[key]; stats[key].source = source.name .. " / " .. incomingStats[key].source
            end
        end
        for _, key in ipairs({"rod", "bait", "ability", "pet"}) do
            if equipment[key].status == "unknown" and incoming[key].status ~= "unknown" then
                equipment[key] = incoming[key]; equipment[key].source = source.name .. " / " .. incoming[key].source
            elseif key == "rod" and incoming.rod.enchantKnown then
                local sameRod = equipment.rod.uuid and equipment.rod.uuid == incoming.rod.uuid
                    or (not equipment.rod.uuid and equipment.rod.id and tostring(equipment.rod.id) == tostring(incoming.rod.id))
                if sameRod then
                    if not equipment.rod.enchantKnown then equipment.rod.enchants = incoming.rod.enchants; equipment.rod.enchantKnown = true end
                    for _, index in ipairs({1, 2}) do
                        local field = "enchant" .. index
                        if not equipment.rod[field .. "Known"] and incoming.rod[field .. "Known"] then
                            equipment.rod[field] = incoming.rod[field]; equipment.rod[field .. "Known"] = true
                        end
                    end
                end
            end
        end
    end
    if equipment.rod.status ~= "none" and (equipment.rod.enchant1Known or equipment.rod.enchant2Known) then
        local names = {}
        if equipment.rod.enchant1Known and equipment.rod.enchant1 ~= "Tidak ada" then table.insert(names, equipment.rod.enchant1) end
        if equipment.rod.enchant2Known and equipment.rod.enchant2 ~= "Tidak ada" then table.insert(names, equipment.rod.enchant2) end
        equipment.rod.enchants = #names > 0 and table.concat(names, ", ") or "Tidak ada"
    end
    state.equipment = equipment
    state.playerStats = stats
    state.equipmentDiagnosticReader = function()
    local statLines = {}
    for _, key in ipairs({"coins", "caught", "rarestFish"}) do
        local slot = stats[key]
        table.insert(statLines, key .. ": " .. slot.display .. " | nilai: " .. tostring(slot.value) .. " | " .. slot.source)
    end
    local statFields = Core.playerStats(state.profileData or state.equipmentProfileData or (eventProfile and eventProfile.data), player.UserId).fields
    state.statsDiagnostics = "Statistik akun lokal:\n" .. table.concat(statLines, "\n") .. "\nField statistik profile: " .. #statFields
        .. (#statFields > 0 and ("\n" .. table.concat(statFields, "\n")) or " | Belum tersedia")
    state.equipmentDiagnostics = "Equip Rod: " .. equipment.rod.name .. " | " .. equipment.rod.source
        .. "\nEnchant rod aktif: " .. equipment.rod.enchants .. "\nEnchant 1: " .. equipment.rod.enchant1
        .. "\nEnchant 2: " .. equipment.rod.enchant2 .. "\nEquip Bait: " .. equipment.bait.name .. " | " .. equipment.bait.source
        .. "\nEquip Ability: " .. equipment.ability.name .. " | " .. equipment.ability.source
        .. "\nEquip Pet: " .. equipment.pet.name .. " | " .. equipment.pet.source
        .. "\nEquipment events: " .. tostring(state.equipmentObserved.accepted)
        .. "\nScope equip event: " .. tostring(eventProfile and (eventProfile.scopeReason or "ID sesuai channel inventory yang teramati")
            or (state.profileData and "Equip diperiksa langsung dari profile snapshot aktif; ID event belum terhubung")
            or "Belum ada profile equip terhubung")
    local fieldLines = Core.equipmentFields(state.profileData or state.equipmentProfileData or (eventProfile and eventProfile.data), player.UserId)
    state.equipmentDiagnostics = state.equipmentDiagnostics .. "\nField equip profile: " .. tostring(#fieldLines)
        .. (#fieldLines > 0 and ("\n" .. table.concat(fieldLines, "\n")) or " | Belum tersedia")
        .. "\nField enchant rod aktif:\n" .. table.concat(equipment.rod.enchantFields or {}, "\n")
    end
end
state.tradeMessage = "Kontrol trade tersedia melalui website."
state.TradeChoices = function(completed)
    local read = completed or state.completedRead
    local inventory = read and read.isolated and read.inventory or state.currentInventory
    local prepared = read and read.inventory == inventory
        and (read.isolated or not state.busy and read.catalog == state.catalog and read.generation == (state.inputGeneration or 0)) and read.flat or nil
    local choices = Core.tradeChoices(inventory or {}, read and read.isolated and read.catalog or state.catalog, prepared, workCheckpoint())
    local rap
    for _, entry in ipairs(state.clients) do
        rap = Core.clientLookup(entry.client, "RAP")
        if rap then break end
    end
    if rap then
        for _, row in ipairs(choices) do
            row.trade.rap = Core.tradeRAP(rap.Data, row.category, row.id) or row.trade.rap
        end
    end
    return choices
end
local function tradeLocalInventory()
    while state.catalogApplying and state.alive do task.wait() end
    local replion = state.replion
    local data = replion and not replion.Destroyed and replion.Data
    if not state.alive or type(data) ~= "table" or state.partial or not (state.catalogReady or state.catalogLabelsReady) then return nil, "Tunggu pembacaan stok akun dan informasi item" end
    if not Core.profileScope(data, player.UserId, replion._channel or "Data", replion.ReplicateTo == "All", CONFIG.ReplionChannels) then return nil, "Profile bukan akun lokal" end
    local inventory = Core.inventory(data, CONFIG.InventoryPaths)
    if not inventory then return nil, "Snapshot inventory tidak tersedia" end
    return Core.withProfileAbilities(inventory, data, player.UserId, state.catalog)
end
state.ReadTradeStock = function(requests)
    local inventory, reason = tradeLocalInventory()
    if not inventory then return nil, reason end
    local stock = Core.captureGraph(inventory, CONFIG.MaxInventoryNodes)
    local catalog = Core.captureGraph(state.catalog, CONFIG.MaxInventoryNodes)
    local checkpoint = workCheckpoint()
    local flat = Core.normalize(stock, catalog, {CollectRecords = true, Checkpoint = checkpoint})
    if flat.truncated then return nil, "Pembacaan stok terpotong" end
    local choices = Core.tradeChoices(stock, catalog, flat, checkpoint)
    local byKey, unresolved, result = {}, {}, {}
    for _, row in ipairs(choices) do byKey[row.key] = row end
    for _, candidate in ipairs(flat.rows) do
        checkpoint()
        if not Core.itemReady(candidate) then
            unresolved[candidate.category] = unresolved[candidate.category] or {}
            unresolved[candidate.category][tostring(candidate.id)] = true
        end
    end
    for _, item in ipairs(requests or {}) do
        local row = byKey[item.key]
        if item.byItem then
            local category,id=item.key:match("^([^%z]*)%z([^%z]*)")
            if (unresolved[category] and unresolved[category][id]) or (unresolved.Uncategorized and unresolved.Uncategorized[id]) then return nil,"Informasi item tujuan belum selesai dipetakan" end
            row=nil
            for _,candidate in ipairs(choices) do if Core.tradeRequestMatches(item,candidate.key) then
                if not Core.itemReady(candidate) then return nil,"Informasi item tujuan belum selesai dipetakan" end
                if not row then row={qty=0,lockedQty=0,trade={verifiedUnits=0,unknownUnits=0},resolved=true,name=candidate.name,icon=candidate.icon,key=item.key} end
                row.qty+=candidate.qty;row.lockedQty+=candidate.lockedQty or 0
                row.trade.verifiedUnits+=candidate.trade.verifiedUnits;row.trade.unknownUnits+=candidate.trade.unknownUnits
            end end
        end
        if row and not Core.itemReady(row) then return nil, "Informasi item tujuan belum selesai dipetakan" end
        if not row then
            local category, id = item.key:match("^([^%z]*)%z([^%z]*)")
            if unresolved[category] and unresolved[category][id] or unresolved.Uncategorized and unresolved.Uncategorized[id] then return nil, "Informasi item tujuan belum selesai dipetakan" end
        end
        local qty = row and row.qty or 0
        local eligible = row and row.trade and (row.trade.verifiedUnits + row.trade.unknownUnits) or 0
        table.insert(result, {key = item.key, qty = qty, available = math.max(0, math.min(qty - (row and row.lockedQty or 0), eligible))})
    end
    return result
end
state.PrepareTrade = function(targetId, requests)
    local target = tonumber(targetId) and Players:GetPlayerByUserId(tonumber(targetId))
    if not target or target == player then return false, "Pilih player target yang masih berada di server" end
    local inventory, err = tradeLocalInventory()
    if not inventory then return false, err end
    local plan, reason = Core.tradePlan(inventory, state.catalog, requests, {localUserId = player.UserId,
        targetUserId = target.UserId, fullSnapshot = true, catalogReady = state.catalogReady, itemCatalogReady = state.catalogLabelsReady})
    if not plan then return false, reason end
    plan.targetName = target.Name; state.tradePlan = plan; state.tradeTarget = target.UserId
    plan.batches = Core.tradeExecutionBatches(plan)
    state.tradeMessage = "Rencana " .. plan.total .. " unit, " .. #plan.batches .. " trade. Klik Mulai; target menyetujui tiap trade."
    status(state.tradeMessage); state.renderInfo()
    return true, plan
end
-- Only these calls are authorized by Mulai. Signatures come from the supplied game sources.
local function tradeReplion(channel)
    for _, entry in ipairs(state.clients) do
        local value = Core.clientLookup(entry.client, channel)
        if value then return value end
        for replion in pairs(entry.added or {}) do
            if not replion.Destroyed and replion._channel == channel then return replion end
        end
        local readers = Core.cacheReaders({env.debug or false, debug or false}, {
            getupvalues = env.getupvalues or getupvalues, getupvalue = env.getupvalue or getupvalue,
        })
        for _, candidate in ipairs(Core.clientCandidates(entry.client, {channel}, readers)) do
            local replion = candidate.value
            if not replion.Destroyed and replion._channel == channel then return replion end
        end
    end
end
local function tradeAdapter()
    if state.tradeAdapter then return state.tradeAdapter end
    local function load(path)
        local module = instancePath(path)
        if not module or not module:IsA("ModuleScript") then error("Modul trade belum tersedia: " .. table.concat(path, "."), 0) end
        local lastError
        for _, loader in ipairs(Core.requireLoaders(require, env.getrenv or getrenv)) do
            local ok, value = boundedRequire(module, loader.call, 5)
            if ok and type(value) == "table" then return value end
            lastError = value
        end
        error("Modul trade tidak dapat dibaca: " .. tostring(lastError), 0)
    end
    local data = load({"Shared", "Trading", "TradeData"})
    local utility = state.definitionUtility or load({"Shared", "ItemUtility"})
    if type(data.FollowTradeRules) ~= "function" or data.MaxItemsInTrade ~= 20
        or type(utility.GetItemDataFromItemType) ~= "function" or type(data.Remotes) ~= "table"
        or type(data.ConfirmCountdownTime) ~= "number" or data.ConfirmCountdownTime < 0 or data.ConfirmCountdownTime > 60 then
        error("Adapter berbeda dari source trade yang diberikan", 0)
    end
    for _, name in ipairs({"SendTradeOffer", "AddItem", "SetReady", "ConfirmTrade", "CancelTrade"}) do
        local remote = data.Remotes[name]
        if typeof(remote) ~= "Instance" or not remote:IsA("RemoteFunction") then error("RemoteFunction tidak tersedia: " .. name, 0) end
    end
    for _, name in ipairs({"TradeStarted", "TradeEnded", "TradeCompleted"}) do
        local remote = data.Remotes[name]
        if typeof(remote) ~= "Instance" or not remote:IsA("RemoteEvent") then error("RemoteEvent tidak tersedia: " .. name, 0) end
    end
    local adapter = {data = data, utility = utility, remotes = data.Remotes}
    state.tradeAdapter = adapter
    return adapter
end
state.ResolveTradeAdapter = tradeAdapter
local function ownedTradeRecords(inventory, slots, checkpoint)
    local wanted,found,visited={},{},0
    for _,slot in ipairs(slots) do wanted[slot.sourceUUID]=true end
    for kind, records in pairs(inventory) do
        if type(records) == "table" then
            for _, record in pairs(records) do
                if checkpoint then checkpoint() end
                visited = visited + 1
                if visited > CONFIG.MaxInventoryNodes then error("Snapshot terlalu besar untuk memeriksa UUID", 0) end
                local uuid=type(record)=="table" and Core.uuid(record.UUID)
                if uuid and wanted[uuid] then
                    if found[uuid] then error("UUID inventory berulang", 0) end
                    found[uuid]={record=record,collection=kind}
                end
            end
        end
    end
    for uuid in pairs(wanted) do if not found[uuid] then error("UUID pilihan sudah tidak dimiliki: " .. uuid, 0) end end
    return found
end
state.TradeOwnedRecords=ownedTradeRecords
local function autoSummary(ctx)
    local replion = ctx.replion and not ctx.replion.Destroyed and ctx.replion or (ctx.channel and tradeReplion(ctx.channel))
    if not replion or replion.Destroyed then return nil end
    local summary, err = Core.tradeSessionSummary(replion.Data, player.UserId, ctx.target.UserId, ctx.channel)
    if not summary then error(err, 0) end
    ctx.replion = replion; ctx.lastSummary = summary
    ctx.journal.lastSession = summary
    return summary
end
local function autoCheck(ctx)
    if not state.alive or state.autoTrade ~= ctx or ctx.stopped then error(ctx.reason or "Auto trade dihentikan", 0) end
    if ctx.failure then error(ctx.failure, 0) end
    if Players:GetPlayerByUserId(ctx.target.UserId) ~= ctx.target then error("Target meninggalkan server", 0) end
    if workspace:GetAttribute("TradingDisabled") ~= false then error("Trading game sedang dinonaktifkan/belum tersedia", 0) end
end
local function autoWait(ctx, seconds, message, predicate)
    ctx.deadline = os.clock() + seconds; ctx.message = message
    state.tradeMessage = "Trade " .. ctx.batchIndex .. "/" .. #ctx.batches .. ": " .. message
    status(state.tradeMessage)
    repeat
        autoCheck(ctx)
        local result = predicate()
        if result then return result end
        task.wait(0.1)
    until os.clock() >= ctx.deadline
    error(message .. ": batas waktu; pengiriman tidak diulang otomatis", 0)
end
local function autoRpc(ctx, name, ...)
    autoCheck(ctx)
    local args = table.pack(...)
    -- No raw call log; the pending lock remains part of transaction correctness.
    local done, result = false, nil
    ctx.rpcPending = true
    state.tradeOutstanding = (state.tradeOutstanding or 0) + 1
    spawnTask(function()
        result = table.pack(pcall(function() return ctx.adapter.remotes[name]:InvokeServer(table.unpack(args, 1, args.n)) end))
        done = true; ctx.rpcPending = false
        state.tradeOutstanding = math.max(0, (state.tradeOutstanding or 1) - 1)
        if ctx.stopped and name == "SendTradeOffer" then state.tradeRetryAfter = os.clock() + 12 end
    end)
    autoWait(ctx, 10, name, function() return done end)
    autoCheck(ctx)
    -- The controller ignores Ready/Confirm return values; their replicated flags must prove the effect.
    local ignoredReturn = (name == "SetReady" or name == "ConfirmTrade") and result[2] == nil and result[3] == nil
    if not result[1] or (result[2] ~= true and not ignoredReturn) then error(name .. " ditolak: " .. tostring(result[1] and result[3] or result[2]), 0) end
end
local function autoOffer(ctx, slots, quantities)
    local summary = autoSummary(ctx)
    if not summary then error("Sesi trade sudah tidak tersedia", 0) end
    local matches, reason = Core.tradeOfferMatches(summary, slots, quantities)
    if not matches then error(reason, 0) end
    return summary
end
local function anotherTradeSession(ctx)
    local function different(replion)
        if replion.Destroyed or replion._channel == ctx.channel then return false end
        local data = replion.Data
        if type(data) ~= "table" or type(data.PlayerList) ~= "table" then return false end
        for _, participant in pairs(data.PlayerList) do
            local ok, id = pcall(function() return participant.UserId end)
            if ok and id == player.UserId then return true end
        end
        return false
    end
    for _, entry in ipairs(state.clients) do
        for replion in pairs(entry.added or {}) do if different(replion) then return true end end
        for _, candidate in ipairs(Core.clientCandidates(entry.client, {}, {})) do
            if different(candidate.value) then return true end
        end
    end
    return false
end
state.StopAutoTrade = function(reason)
    local ctx = state.autoTrade
    state.RestorePanel()
    if not ctx then return false end
    ctx.stopped = true; ctx.reason = reason or "Dihentikan pengguna"
    state.lastTradeOutcome = ctx
    if state.NotifyTradeFinished then state.NotifyTradeFinished(ctx, ctx.reason) end
    state.autoTrade = nil
    if not ctx.success then state.tradeRetryAfter = os.clock() + 12 end
    ctx.journal.recording = false; ctx.journal.finishedAt = os.time(); ctx.journal.stopReason = ctx.reason
    for _, connection in ipairs(ctx.connections) do pcall(function() connection:Disconnect() end) end
    state.tradeMessage = ctx.reason .. " | selesai " .. ctx.finished .. "/" .. #ctx.batches .. " trade. Trade > Salin."
    status(state.tradeMessage); state.renderInfo(); if state.RenderTrade then state.RenderTrade() end
    -- Cancel only our still-matching session. An outstanding request may still return later.
    if not ctx.success and not ctx.rpcPending and ctx.adapter and ctx.channel then
        local ok, summary = pcall(autoSummary, ctx)
        if ok and summary then
            spawnTask(function()
                local replion = tradeReplion(ctx.channel)
                if state.autoTrade or not replion or replion ~= ctx.replion or replion.Destroyed then return end
                if anotherTradeSession(ctx) then return end
                local matched = Core.tradeSessionSummary(replion.Data, player.UserId, ctx.target.UserId, ctx.channel)
                if not matched then return end
                -- Cancel only the verified session; no recording.
                state.tradeOutstanding = (state.tradeOutstanding or 0) + 1
                local called, result, err = pcall(function() return ctx.adapter.remotes.CancelTrade:InvokeServer() end)
                state.tradeOutstanding = math.max(0, (state.tradeOutstanding or 1) - 1)
                if not called or result == false then state.tradeError = tostring(err or result) end
            end)
        end
    end
    return true
end
state.StartAutoTrade = function(targetId, requests)
    if state.autoTrade then return state.StopAutoTrade("Dihentikan pengguna") end
    if state.tradeJournal and state.tradeJournal.recording then return false, "Hentikan rekaman sebelum Mulai auto trade" end
    if (state.tradeOutstanding or 0) > 0 or os.clock() < (state.tradeRetryAfter or 0) then
        return false, "Permintaan sebelumnya belum selesai/kedaluwarsa; periksa GUI game dan tunggu sebelum mulai ulang"
    end
    local ok, plan = state.PrepareTrade(targetId, requests)
    if not ok then return false, plan end
    local target = Players:GetPlayerByUserId(plan.targetUserId)
    local journal = Core.tradeJournal(player.UserId, target.UserId, plan)
    journal.mode = "autoTrade"; journal.startedAt = os.time(); journal.targetName = target.Name
    journal.protocol = "Source-verified calls; Replion participant/offer checks; server completion plus local unit deltas"
    journal.completedBatches = 0
    local ctx = {target = target, plan = plan, batches = plan.batches, batchIndex = 1, finished = 0,
        journal = journal, sentByKey = {}, connections = {}, usedChannels = {}, deadline = os.clock() + 20}
    state.autoTrade = ctx; state.tradeJournal = journal; state.lastTradeFrame = nil; state.nextTradeFrame = 0
    state.HideForTradeRecording()
    spawnTask(function()
        while state.alive and state.autoTrade == ctx do
            local success, err = pcall(function()
                state.SetRecorderControls(ctx.deadline - os.clock())
                -- No GUI scan or recording task.
            end)
            if not success then ctx.failure = "Pembacaan trade gagal: " .. tostring(err) end
            if os.clock() > ctx.deadline + 2 then state.StopAutoTrade("Batas waktu auto trade; periksa GUI game sebelum mulai ulang"); return end
            task.wait(0.5)
        end
    end)
    spawnTask(function()
        local succeeded, failure = pcall(function()
            ctx.adapter = tradeAdapter(); autoCheck(ctx)
            local remotes = ctx.adapter.remotes
            for _, name in ipairs({"TradeStarted", "TradeEnded", "TradeCompleted"}) do
                connect(remotes[name].OnClientEvent, function(...)
                    if state.autoTrade ~= ctx or ctx.stopped then return end
                    local args = table.pack(...)
                    if name == "TradeStarted" then
                        if ctx.phase ~= "invitation" or type(args[1]) ~= "string" or args[1] == "" or ctx.usedChannels[args[1]] then
                            ctx.failure = "TradeStarted tidak cocok dengan undangan batch aktif"
                        else ctx.channel = args[1]; ctx.usedChannels[ctx.channel] = true end
                    elseif name == "TradeEnded" then
                        if ctx.phase ~= "between" and not ctx.completed then ctx.failure = "Trade berakhir: " .. tostring(args[1]) end
                    elseif name == "TradeCompleted" then
                        local summaryOK, summary = pcall(autoSummary, ctx)
                        summary = summaryOK and (summary or ctx.lastSummary) or nil
                        if ctx.phase == "confirmation" and ctx.confirmRequested and summary
                            and summary.localConfirmed == true and summary.targetConfirmed == true then
                            ctx.completed = true
                        end
                    end
                end, ctx.connections)
            end
            for index, batch in ipairs(ctx.batches) do
                ctx.batchIndex = index; ctx.phase = "between"; ctx.channel = nil; ctx.replion = nil
                ctx.lastSummary = nil; ctx.completed = false; ctx.confirmRequested = false; ctx.batchVerified = false; ctx.unconfirmedSlots = nil
                ctx.sessionMissingAt = nil
                autoCheck(ctx)
                -- A finished session may briefly retain IsTrading while the game cleans up.
                autoWait(ctx, 8, "Menunggu player tersedia", function()
                    return not player:GetAttribute("IsTrading") and not target:GetAttribute("IsTrading")
                end)
                local public = tradeReplion("ReplicatedPlayerData")
                local settings = public and public.Data and public.Data["User_" .. target.UserId]
                if not settings or not settings.TradeSettings or not settings.TradeSettings.Trades or settings.TradeSettings.Trades == 0 then
                    error("Target belum dapat menerima undangan trade", 0)
                end
                local inventory, invError = tradeLocalInventory()
                if not inventory then error(invError, 0) end
                local before = Core.tradeInventoryQuantities(inventory, state.catalog, batch.slots)
                local owned=ownedTradeRecords(inventory,batch.slots,workCheckpoint())
                local slots = {}
                for _, unit in ipairs(batch.slots) do
                    local record, collection = owned[unit.sourceUUID].record,owned[unit.sourceUUID].collection
                    local definition = ctx.adapter.utility.GetItemDataFromItemType(collection, record.Id)
                    if not definition or not definition.Data or tostring(definition.Data.Id) ~= tostring(unit.id)
                        or Core.category(definition.Data.Type) ~= unit.category or ctx.adapter.data.FollowTradeRules(definition, record) ~= true
                        or record.Locked == true or record.TradeLocked == true
                        or (type(record.Metadata) == "table" and (record.Metadata.Locked == true or record.Metadata.TradeLocked == true)) then
                        error("Item berubah atau tidak mengikuti aturan trade: " .. unit.name, 0)
                    end
                    local flat = Core.normalize({[collection] = {record}}, state.catalog).rows[1]
                    if not flat or flat.key ~= unit.key then error("Identitas/mutasi pilihan berubah", 0) end
                    local slot = table.clone(unit); slot.itemType = definition.Data.Type; slot.sourceQuantity = before[unit.sourceUUID]
                    slot.tradeStatus = "tradable"; slot.tradeSource = "TradeData.FollowTradeRules (runtime)"
                    if not slot.sourceQuantity or slot.sourceQuantity < 1 then error("Stok pilihan tidak tersedia", 0) end
                    table.insert(slots, slot)
                end
                local result = {index = index, status = "invitation", completion = "unverified"}
                ctx.phase = "invitation"
                autoRpc(ctx, "SendTradeOffer", target)
                autoWait(ctx, ctx.adapter.data.TradeOfferExpiration or 10, "Menunggu target menerima undangan", function()
                    if ctx.channel then return autoSummary(ctx) end
                end)
                result.channel = ctx.channel; journal.targetAcceptance = "sessionParticipantsVerified"
                autoOffer(ctx, {}, false); ctx.phase = "offer"; result.status = "addingItems"
                local added = {}
                for _, slot in ipairs(slots) do
                    autoOffer(ctx, added, false)
                    autoRpc(ctx, "AddItem", slot.itemType, slot.sourceUUID)
                    table.insert(added, slot)
                    autoWait(ctx, 5, "Memeriksa item pada offer", function()
                        local summary = autoSummary(ctx)
                        if not summary then error("Sesi ditutup saat menambah item", 0) end
                        if summary.localOffer.cards < #added then return false end
                        local matches, reason = Core.tradeOfferMatches(summary, added, false)
                        if not matches then error(reason, 0) end
                        return true
                    end)
                end
                autoWait(ctx, 65, "Menunggu kunci perubahan offer", function()
                    local summary = autoOffer(ctx, slots, true)
                    if type(summary.lastModifiedTime) ~= "number" then error("Waktu perubahan offer belum tersedia", 0) end
                    return workspace:GetServerTimeNow() >= summary.lastModifiedTime + ctx.adapter.data.ConfirmCountdownTime
                end)
                result.status = "ready"; autoRpc(ctx, "SetReady", true)
                autoWait(ctx, 120, "Menunggu target Ready", function()
                    local summary = autoOffer(ctx, slots, true)
                    return summary.localReady == true and summary.targetReady == true and summary.playersReady == true
                end)
                local summary = autoOffer(ctx, slots, true)
                if type(summary.lastModifiedTime) ~= "number"
                    or workspace:GetServerTimeNow() < summary.lastModifiedTime + ctx.adapter.data.ConfirmCountdownTime then error("Offer berubah sebelum konfirmasi", 0) end
                ctx.phase = "confirmation"; ctx.confirmRequested = true; result.status = "confirmation"
                ctx.unconfirmedSlots = slots
                autoRpc(ctx, "ConfirmTrade")
                autoWait(ctx, 120, "Menunggu target Confirm dan hasil server", function()
                    if ctx.completed then return true end
                    local active = autoSummary(ctx)
                    if not active then
                        ctx.sessionMissingAt = ctx.sessionMissingAt or os.clock()
                        if not ctx.lastSummary or ctx.lastSummary.localConfirmed ~= true or ctx.lastSummary.targetConfirmed ~= true
                            or os.clock() - ctx.sessionMissingAt > 8 then error("Sesi ditutup tanpa hasil server terverifikasi", 0) end
                        return false
                    end
                    local matches, reason = Core.tradeOfferMatches(active, slots, true)
                    if not matches then error(reason, 0) end
                    if active.localReady ~= true or active.targetReady ~= true or active.playersReady ~= true then error("Ready berubah setelah konfirmasi", 0) end
                end)
                result.serverCompleted = true
                local after = autoWait(ctx, 8, "Memeriksa selisih inventory 1 unit per slot", function()
                    local updated = tradeLocalInventory()
                    if not updated then return false end
                    local quantities = Core.tradeInventoryQuantities(updated, state.catalog, slots)
                    for _, slot in ipairs(slots) do if (before[slot.sourceUUID] or 0) - (quantities[slot.sourceUUID] or 0) ~= 1 then return false end end
                    return quantities
                end)
                -- Exact unit deltas were already verified above; no historical delta log.
                result.status = "completed"; result.completion = "serverConfirmedWithLocalUnitDelta"
                ctx.batchVerified = true
                for _, slot in ipairs(slots) do ctx.sentByKey[slot.key] = (ctx.sentByKey[slot.key] or 0) + 1 end
                state.tradeStockRevision = (state.tradeStockRevision or 0) + 1
                if state.Refresh then state.Refresh() end
                ctx.finished = ctx.finished + 1; journal.completedBatches = ctx.finished; ctx.phase = "between"
                if index < #ctx.batches then autoWait(ctx, 5, "Menyiapkan undangan berikutnya", function() return os.clock() + 0.1 >= ctx.deadline end) end
            end
            ctx.success = true; journal.completion = "serverConfirmedWithLocalUnitDelta"
        end)
        if state.autoTrade == ctx then
            if not succeeded then journal.failure = tostring(failure) end
            state.StopAutoTrade(succeeded and ("Selesai mengirim " .. plan.total .. " unit ke " .. target.Name) or ("Auto trade berhenti: " .. tostring(failure)))
        end
    end)
    return true, plan
end
local function rowSignature(rows)
    local parts = {}
    for _, row in ipairs(rows) do
        table.insert(parts, row.key .. ":" .. tostring(row.qty) .. ":" .. row.icon .. ":" .. tostring(row.resolved) .. ":" .. tostring(row.minWeight) .. ":" .. tostring(row.maxWeight) .. ":" .. tostring(row.favoriteQty) .. ":" .. tostring(row.lockedQty) .. ":" .. table.concat(row.instances, ","))
    end
    return table.concat(parts, "\n")
end
refresh = function(force)
    if not Core.beginRefresh(state, force) then return end
    spawnTask(function()
        local ok, err = pcall(function()
            local generation, checkpoint = state.inputGeneration or 0, workCheckpoint()
            state.readCache = {Checkpoint = checkpoint}
            local inventory, source, partial, readMetadata = readSource()
            if not inventory then status(source or "Inventori belum tersedia"); return end
            local capturedTradeStockRevision = state.tradeStockRevision or 0
            local capture, capturedReplion
            if partial == false and state.replion and not state.replion.Destroyed and state.profileData then
                capturedReplion = state.replion
                local started = os.clock()
                local catalogVersion = Core.catalogVersion(state.catalog)
                local definitions = not state.catalogApplying and state.captureCatalogSource == state.catalog
                    and state.captureCatalogVersion == catalogVersion and state.captureCatalog or nil
                local knownPath = state.stockPath == "Inventory" or state.stockPath == "Data.Inventory"
                    or state.stockPath == "Profile.Inventory" or state.stockPath == "<root>"
                local reconcile = force or not knownPath or not state.captureSubscribed or state.captureAliased or not state.captureBase or state.captureOwner ~= capturedReplion
                    or state.captureReset or os.clock() - (state.captureFullAt or 0) >= 60
                if reconcile then
                    capture = Core.captureRead(inventory, state.profileData, state.catalog, CONFIG.MaxInventoryNodes, definitions)
                    state.captureFullAt = os.clock()
                else
                    local stock, nodes, aliased = Core.captureChanges(state.captureBase, inventory, state.captureChanges or {},
                        capturedReplion._channel, CONFIG.MaxInventoryNodes)
                    capture = {inventory=stock, nodes=nodes, profile=Core.captureGraph(Core.profileProjection(state.profileData), CONFIG.MaxInventoryNodes),
                        catalog=definitions or Core.captureGraph(state.catalog, CONFIG.MaxInventoryNodes), isolated=true,aliased=aliased}
                end
                state.captureBase = capture.inventory; state.captureOwner = capturedReplion
                state.captureAliased = capture.aliased
                state.captureChanges = {}; state.captureReset = false
                if not state.catalogApplying then
                    state.captureCatalogSource = state.catalog; state.captureCatalogVersion = catalogVersion; state.captureCatalog = capture.catalog
                end
                state.captureMs = (os.clock() - started) * 1000; state.captureNodes = capture.nodes
                inventory = capture.inventory; state.profileData = capture.profile
                state.readCache.catalog = capture.catalog; generation = state.inputGeneration or 0
                state.readCache.abilityViews = {[inventory] = {[capture.profile] = inventory}}
                readMetadata = table.clone(readMetadata or {}); readMetadata.capturedAt = os.time()
                state.snapshotPhase = "Normalize snapshot"
            end
            local readCatalog = capture and capture.catalog or state.catalog
            -- Normalization copies owned metadata into the prepared records.
            -- Discard the staged result if the source changes across a yield.
            local stageStarted = os.clock()
            state.normalizeCache = state.normalizeCache or {}
            local flat = Core.normalize(inventory, readCatalog, {
                MaxNodes = CONFIG.MaxInventoryNodes, CollectRecords = true, CollectDefinitions = true, Checkpoint = checkpoint,
                ImmutableCache = capture and state.normalizeCache or nil,
            })
            state.normalizeMs = (os.clock() - stageStarted) * 1000; stageStarted = os.clock()
            state.readCache[inventory] = flat
            readEquipment(inventory, state.readCache); state.renderEquipment()
            state.equipmentMs = (os.clock() - stageStarted) * 1000; stageStarted = os.clock()
            local nextBag
            if state.readCache.replaceBag and not flat.truncated and (not state.completedRead
                or state.completedRead.inventory ~= inventory or state.completedRead.catalog ~= readCatalog or state.bag.pendingComplete) then
                nextBag = table.clone(state.bag)
                Core.bagReplace(nextBag, inventory, readCatalog, "Inventory", flat, checkpoint)
                nextBag.pendingComplete = nil
            end
            state.bagMs = (os.clock() - stageStarted) * 1000
            if not state.alive then return end
            if capture and (state.replion ~= capturedReplion or capturedReplion.Destroyed) then
                state.pendingRefresh = true; return
            end
            if not capture and generation ~= (state.inputGeneration or 0) then
                state.discardedReads = (state.discardedReads or 0) + 1; state.pendingRefresh = true; return
            end
            if nextBag and generation == (state.inputGeneration or 0) then state.bag = nextBag end
            state.currentInventory = inventory
            local previousFlat = state.completedRead and state.completedRead.flat
            state.completedRead = {inventory = inventory, flat = flat, generation = generation, catalog = readCatalog, isolated = capture ~= nil}
            local snapshot = table.clone(flat); snapshot.items = nil
            snapshot.isolated = capture ~= nil; snapshot.sourceGeneration = generation
            snapshot.tradeStockRevision = capturedTradeStockRevision
            state.completedRead.snapshot = snapshot
            state.snapshotPhase = "Snapshot siap"
            partial = partial or snapshot.truncated
            snapshot.partial = partial
            snapshot.catalogReady = state.catalogReady
            snapshot.definitionRequests = nil; snapshot.definitionKeys = nil
            snapshot.mappingComplete = partial == false and snapshot.truncated ~= true and state.catalogLabelsReady == true
                and snapshot.unresolved == 0 and snapshot.missingIcons == 0
            local mutationData=snapshot.mutationDiagnostics
            snapshot.mutationMappingComplete = not partial and mutationData.unmapped==0 and mutationData.invalid==0 and mutationData.unknown==0
            snapshot.cached = readMetadata and readMetadata.cached or false
            snapshot.retainedWidgets = readMetadata and readMetadata.retainedWidgets or false
            snapshot.unresolvedRemovals = partial and state.bag.unresolvedRemovals or 0
            snapshot.equipment = {}
            snapshot.playerStats = {}
            for _, key in ipairs({"coins", "caught", "rarestFish"}) do snapshot.playerStats[key] = state.playerStats[key] end
            if state.fishingRunId then
                state.fishingHistory,snapshot.fishing=Core.fishingObserve(state.fishingHistory,state.profileData,flat,
                    {runId=state.fishingRunId,source=state.replion or source,inventory=capture and inventory or nil,catalog=readCatalog,at=os.time(),caught=snapshot.playerStats.caught and snapshot.playerStats.caught.value,
                        complete=not partial and not flat.truncated and flat.unresolved==0,trading=state.autoTrade~=nil or player:GetAttribute("IsTrading")==true},checkpoint)
            end
            for key, slot in pairs(state.equipment) do snapshot.equipment[key] = {name = slot.name, id = slot.id, uuid = slot.uuid,
                status = slot.status, source = slot.source, enchants = slot.enchants, enchantKnown = slot.enchantKnown,
                enchant1 = slot.enchant1, enchant2 = slot.enchant2, enchant1Known = slot.enchant1Known, enchant2Known = slot.enchant2Known}
                if slot.items then
                    snapshot.equipment[key].items = {}
                    for _, item in ipairs(slot.items) do table.insert(snapshot.equipment[key].items,
                        {name = item.name, id = item.id, uuid = item.uuid, status = item.status}) end
                end
            end
            local itemCollection = Core.path(inventory, CONFIG.ItemPath)
            snapshot.itemRecords = 0
            if type(itemCollection) == "table" then
                for _, item in pairs(itemCollection) do if type(item) == "table" then snapshot.itemRecords = snapshot.itemRecords + 1 end end
            end
            snapshot.categories = Core.categoryTotals(snapshot.rows)
            local categoryLines = {}
            for _, entry in ipairs(snapshot.categories) do
                table.insert(categoryLines, entry.category .. ": " .. entry.quantity .. " unit; " .. entry.records
                    .. " record; " .. entry.groups .. " kelompok; belum dipetakan: " .. entry.unresolved)
            end
            local signature = source .. "\n" .. rowSignature(snapshot.rows)
            local changed = signature ~= state.signature or not previousFlat or not Core.dataEqual(previousFlat.items,flat.items,checkpoint)
                or not Core.dataEqual(state.snapshot and state.snapshot.fishing,snapshot.fishing,checkpoint)
            state.signature = signature; state.baselineSource = source; state.lastTruncated = snapshot.truncated
            state.baselineCatalog = state.catalog.count
            if changed or state.partial ~= partial then state.revision = state.revision + 1 end
            state.rows = snapshot.rows; state.snapshot = snapshot; state.source = source
            if state.QueueDefinitions then state.QueueDefinitions(flat.definitionRequests or {}) end
            state.capturedAt = readMetadata and readMetadata.capturedAt or os.time(); state.partial = partial
            snapshot.capturedAt = state.capturedAt
            state.diagnosticsReader = function() return table.concat({
                "Info diperbarui: " .. os.date("%H:%M:%S"),
                "Player: " .. player.Name .. " | PlaceId: " .. tostring(game.PlaceId),
                "LocalPlayer.UserId: " .. tostring(player.UserId),
                "Area GUI dipilih: " .. tostring(state.guiInventoryRoot and state.guiInventoryRoot:GetFullName() or "Path tas otomatis belum termuat"),
                "Widget tas diklik: " .. tostring(state.clickedGuiPath or "Belum ada"),
                "Pemilihan GUI: " .. tostring(state.pickError or "Tidak ada error"),
                "Mode pemilihan tas: " .. tostring(state.guiSelectionSource or "Otomatis; menunggu data client/widget"),
                state.equipmentDiagnostics or "Equip belum diperiksa",
                "Trade: " .. tostring(state.tradeMessage or "Pilih target dan item melalui tombol Trade"),
                state.statsDiagnostics or "Statistik belum diperiksa",
                table.concat(state.ownerNotes or {}, "\n"),
                "Source: " .. source,
                "Waktu ekstraksi data: " .. os.date("%H:%M:%S", state.capturedAt) .. " | cache terakhir: " .. tostring(snapshot.cached),
                "Tanpa membuka tas: pembacaan otomatis aktif | snapshot inventory penuh: " .. tostring(not partial),
                "Cache execute sebelumnya: " .. tostring(state.reusedCache == true) .. " (hanya PlayerGui dan UserId sesi yang sama)",
                "Replion module: " .. (state.modulePath or state.moduleError or "Belum ditemukan"),
                "Client readers: " .. tostring(#state.clients) .. "; replion snapshot candidates: " .. tostring(state.liveCandidates or 0),
                "Introspeksi cache client: " .. tostring(state.cacheCapability or "Belum diperiksa"),
                table.concat(state.clientProbeNotes or {}, "\n"),
                "Profile shape: " .. describeShape(state.profileData),
                "Ability dari Profile.Abilities.Inventory: " .. tostring(state.abilityAdditions) .. " record",
                "Equipment error: " .. tostring(state.equipmentError or "Tidak ada"),
                "Reader aktif: " .. tostring(state.activeReader or "Belum menemukan snapshot penuh"),
                table.concat(state.discoveryNotes, "\n"),
                state.guiDiagnostics or "GUI cadangan belum diperlukan/diperiksa",
                state.dataShape or "Channel data belum tersedia",
                "Inventory shape: " .. describeShape(inventory),
                "Inventory.Items: " .. describeShape(itemCollection) .. " | record teramati: " .. tostring(snapshot.itemRecords),
                "Replion remote listeners: " .. tostring(state.remoteCount) .. " | " .. (state.remotePath or "Belum tersedia"),
                "Inventory events: " .. tostring(state.observed.accepted) .. "; non-inventory diabaikan: " .. tostring(state.observed.ignored),
                "Protocol terakhir: " .. tostring(state.observed.lastPath or "Belum ada update Inventory"),
                "Item event terakhir: " .. describeShape(state.observed.lastItem),
                "Payload ditolak: " .. tostring(state.observed.rejected) .. " | " .. tostring(state.observed.lastError or "Tidak ada"),
                state.observedWarning or (partial and "Snapshot lama tidak dapat dipulihkan hanya dari update ikan baru."
                    or "Snapshot Inventory penuh terbaca pada client."),
                "Rows: " .. tostring(#state.rows) .. "; total: " .. tostring(snapshot.total),
                "Total adalah jumlah kuantitas seluruh kategori yang terbaca.",
                "Rincian kategori:\n" .. table.concat(categoryLines, "\n"),
                "Belum dipetakan: " .. tostring(snapshot.unresolved) .. "; tanpa ikon: " .. tostring(snapshot.missingIcons),
                "Contoh ID/definisi belum lengkap:\n" .. Core.unmappedCatalogRows(snapshot.rows),
                Core.mutationDiagnostics(snapshot),
                "Pemetaan item lengkap: " .. tostring(snapshot.mappingComplete) .. " | kelengkapan data dan katalog diperiksa terpisah",
                "Pemetaan mutasi lengkap: " .. tostring(snapshot.mutationMappingComplete) .. " | field yang hilang tetap belum terbaca",
                "Skipped: " .. tostring(snapshot.skipped) .. "; truncated: " .. tostring(snapshot.truncated),
                "Parsial: " .. tostring(partial) .. " | Polling: " .. tostring(CONFIG.RefreshSeconds) .. " detik",
                "Scope: inventory akun lokal yang tersedia pada client, bukan seluruh player server.",
            }, "\n") end
            if changed or force then refreshCategories(); render() end
            local note = partial and " | PARSIAL: bukan total tas" or ""
            if snapshot.truncated then note = note .. " | DATA TERPOTONG" end
            if snapshot.unresolved > 0 then note = note .. " | " .. tostring(snapshot.unresolved) .. " belum dipetakan" end
            if not state.catalogReady then note = note .. " | Memuat katalog" end
            status(os.date("%H:%M:%S") .. " | " .. source .. note)
        end)
        if not ok and state.alive then
            status("Baca gagal; snapshot dipertahankan. Klik Info.")
            -- Keep one current error, without accumulating diagnostic history.
            state.lastError = tostring(err)
        end
        state.renderLoading(); state.renderInfo()
        state.readCache = nil
        local pending, forced = Core.endRefresh(state)
        if pending then refresh(forced) end
    end)
end

local function addLabels(value, target)
    if type(value) ~= "table" then return end
    for key, descriptor in pairs(value) do
        if type(descriptor) == "table" then
            local data = type(descriptor.Data) == "table" and descriptor.Data or descriptor
            local name = data.Name or data.DisplayName
            if type(name) == "string" then
                target[tostring(data.Id or key)] = name
                target[tostring(key)] = name
            end
        elseif type(descriptor) == "string" then target[tostring(key)] = descriptor end
    end
    Core.touchCatalog(state.catalog)
end
local function updateCatalogView(force)
    local now = os.clock()
    if not force and now < (state.nextCatalogView or 0) then return end
    state.nextCatalogView = now + 0.5
    state.renderLoading(); state.renderInfo()
end
-- Included in the collector by the build script, not a second entrypoint.
local function loadCatalogModules(entries, labels, consume, checkpoint)
    local workers = math.clamp(math.floor(tonumber(CONFIG.CatalogWorkers) or 1), 1, 4)
    for first = 1, #entries, workers do
        if not state.alive then return end
        local jobs = {}
        for index = first, math.min(#entries, first + workers - 1) do
            local entry, job = entries[index], {done = false}
            job.entry = entry
            job.thread = spawnTask(function()
                job.ok, job.value = pcall(require, entry.module)
                job.done = true
            end)
            table.insert(jobs, job)
        end
        local deadline = os.clock() + CONFIG.RequireTimeout
        repeat
            local complete = true
            for _, job in ipairs(jobs) do if not job.done then complete = false; break end end
            if complete or not state.alive or os.clock() >= deadline then break end
            task.wait()
        until false
        -- Merge in discovery order, even when requires finish out of order.
        state.catalogApplying = true
        state.inputGeneration = (state.inputGeneration or 0) + 1
        for _, job in ipairs(jobs) do
            if not job.done then
                pcall(task.cancel, job.thread); state.tasks[job.thread] = nil
                job.ok, job.value = false, "Module timeout: " .. job.entry.module.Name
            end
            if state.alive then
                state.catalogModule = job.entry.module:GetFullName()
                state.catalogModules = state.catalogModules + 1
                if job.ok and type(job.value) == "table" then consume(job.entry, job.value)
                else
                    if labels then state.catalogLabelFailures = state.catalogLabelFailures + 1
                    else state.catalogFailures = state.catalogFailures + 1 end
                    state.catalogLastFailure = state.catalogModule .. " | " .. tostring(job.ok and ("Hasil require: " .. type(job.value)) or job.value)
                end
                checkpoint()
            end
        end
        state.catalogApplying = false
        state.inputGeneration = (state.inputGeneration or 0) + 1
        if not state.alive then return end
        updateCatalogView()
    end
end
-- Definition cache lasts for this execution. Requests never contain quantities/UUIDs.
state.catalog.definitionScoped = true
Core.touchCatalog(state.catalog)
local function definitionWake(delay)
    if not state.alive then return end
    local due = os.clock() + (delay or 0)
    if state.definitionWakeAt and state.definitionWakeAt <= due then return end
    if state.definitionWakeThread then
        pcall(task.cancel, state.definitionWakeThread); state.tasks[state.definitionWakeThread] = nil
    end
    state.definitionWakeAt = due
    state.definitionWakeThread = spawnTask(function()
        task.wait(math.max(0, due - os.clock()))
        state.definitionWakeThread = nil; state.definitionWakeAt = nil
        if state.alive and not state.catalogBuilding and state.ResolveDefinitions then state.ResolveDefinitions() end
    end)
end
state.QueueDefinitions = function(requests)
    state.definitionRequests = requests
    local earliest
    for _, request in ipairs(requests) do
        if not Core.definitionReady(state.catalog, request) then
            local retry = state.definitionRetries and state.definitionRetries[request.key] or 0
            earliest = math.min(earliest or math.huge, retry)
        end
    end
    state.catalogReady = state.catalogLabelsReady == true and earliest == nil
    if earliest and not state.catalogBuilding then definitionWake(math.max(0, earliest - os.clock())) end
end
local function definitionUtility()
    if state.definitionUtility then return state.definitionUtility end
    if os.clock() < (state.definitionUtilityRetry or 0) then return nil end
    state.definitionUtilityRetry = os.clock() + 30
    local module = instancePath({"Shared", "ItemUtility"})
    if not module or not module:IsA("ModuleScript") then return nil end
    for _, loader in ipairs(Core.requireLoaders(require, env.getrenv or getrenv)) do
        local ok, value = boundedRequire(module, loader.call, CONFIG.RequireTimeout)
        if ok and type(value) == "table" and type(value.GetItemDataFromItemType) == "function" then
            state.definitionUtility = value; return value
        end
        state.catalogLastFailure = "ItemUtility | " .. tostring(value)
    end
    return nil
end
local function definitionCursor(collection, category, checkpoint)
    state.definitionFallback = state.definitionFallback or {}
    local cursor = state.definitionFallback[collection]
    if cursor and (not cursor.finished or os.clock() < cursor.retryAt) then return cursor end
    cursor = {stack = {}, seen = {}, finished = false, retryAt = os.clock() + 60,
        generation = cursor and cursor.generation + 1 or 1}
    local roots = {}
    for _, path in ipairs(CONFIG.CatalogPaths) do
        local rootCategory = Core.catalogCategory(path[#path])
        if (collection == "Items" and (path[#path] == "Items" or rootCategory == "Fish" or rootCategory == "Gears" or rootCategory == "Trophies"))
            or (collection ~= "Items" and (rootCategory == Core.category(category) or path[#path] == collection)) then
            local root = instancePath(path)
            if root and not roots[root] then
                roots[root] = true
                table.insert(cursor.stack, {item = root, category = rootCategory})
            end
        end
        checkpoint()
    end
    -- Direct roots are visited before alternative roots, in configured order.
    local reversed = {}; for index = #cursor.stack, 1, -1 do table.insert(reversed, cursor.stack[index]) end
    cursor.stack = reversed; state.definitionFallback[collection] = cursor
    return cursor
end
local function resolveDefinitionBatch(requests, utility, pending, checkpoint)
    local workers = math.clamp(math.floor(tonumber(CONFIG.CatalogWorkers) or 1), 1, 4)
    local function missing(request)
        local group = pending[request.collection] or {category = request.category, requests = {}}
        pending[request.collection] = group; table.insert(group.requests, request)
    end
    for first = 1, #requests, workers do
        if not state.alive then return end
        local jobs = {}
        for index = first, math.min(#requests, first + workers - 1) do
            local request, job = requests[index], {done = false}
            job.request = request; table.insert(jobs, job)
            if utility then
                state.definitionLookups += 1
                job.thread = spawnTask(function()
                    job.ok, job.value = pcall(utility.GetItemDataFromItemType, request.collection, request.id or request.name)
                    job.done = true
                end)
            else job.done = true end
        end
        local deadline = os.clock() + CONFIG.RequireTimeout
        repeat
            local complete = true; for _, job in ipairs(jobs) do if not job.done then complete = false; break end end
            if complete or not state.alive or os.clock() >= deadline then break end
            task.wait()
        until false
        state.catalogApplying = true; state.inputGeneration = (state.inputGeneration or 0) + 1
        for _, job in ipairs(jobs) do
            if not job.done then
                pcall(task.cancel, job.thread); state.tasks[job.thread] = nil
                job.ok, job.value = false, "Batas waktu lookup ID"
            end
            if state.alive then
                local ready = job.ok and Core.acceptDefinition(state.catalog, job.request, job.value)
                if ready then state.definitionRetries[job.request.key] = nil
                else
                    missing(job.request)
                    if utility and not job.ok then state.catalogLastFailure = "ID " .. tostring(job.request.id or job.request.name) .. " | " .. tostring(job.value) end
                end
            end
        end
        state.catalogApplying = false; state.inputGeneration += 1
        checkpoint()
    end
end
local function scanCatalog()
    local checkpoint = workCheckpoint()
    state.definitionRetries = state.definitionRetries or {}
    state.definitionModules = state.definitionModules or {}
    state.definitionLookups = state.definitionLookups or 0
    state.definitionCacheHits = state.definitionCacheHits or 0
    state.catalogRoots = state.catalogRoots or {}
    state.definitionLabelModules = state.definitionLabelModules or {}
    if not state.catalogLabelsReady then
        -- Small label catalogs are independent of account ownership.
        for _, config in ipairs({{name = "Rarity", paths = CONFIG.TierPaths, target = state.catalog.tiers},
            {name = "Mutasi", paths = CONFIG.VariantPaths, target = state.catalog.variants},
            {name = "Enchant", paths = CONFIG.EnchantPaths, target = state.catalog.enchants}}) do
            state.catalogPhase = config.name
            local entries, modules = {}, {}
            for _, path in ipairs(config.paths) do
                local root = instancePath(path)
                if root then
                    if root:IsA("ModuleScript") then
                        if not modules[root] and not state.definitionLabelModules[root] then modules[root] = true; table.insert(entries, {module = root}) end
                    else
                        for _, module in ipairs(root:GetChildren()) do
                            if module:IsA("ModuleScript") and not modules[module] and not state.definitionLabelModules[module] then
                                modules[module] = true; table.insert(entries, {module = module, wrap = true})
                            end
                        end
                    end
                end
                checkpoint()
            end
            loadCatalogModules(entries, true, function(entry, value)
                addLabels(entry.wrap and {[entry.module.Name] = value} or value, config.target)
                state.definitionLabelModules[entry.module] = true
            end, checkpoint)
            if not state.alive then return end
        end
        local labels = table.clone(state.catalog.variants)
        for id, name in pairs(labels) do Core.addMutation(state.catalog, name, id); checkpoint() end
        state.mutationCount = 0; for _ in pairs(state.catalog.mutationNames) do state.mutationCount += 1 end
        -- Retry incomplete labels later without blocking already readable items.
        state.catalogLabelsReady = state.catalogLabelFailures == 0
    end
    if not state.alive then return end
    state.catalogPhase = "ID milik akun"
    local requests = state.definitionRequests or {}
    if #requests == 0 then state.catalogReady = state.catalogLabelsReady; return end
    local utility = definitionUtility()
    local pending, lookupRequests, now = {}, {}, os.clock()
    for _, request in ipairs(requests) do
        if not state.alive then return end
        if Core.definitionReady(state.catalog, request) then state.definitionCacheHits += 1
        elseif now >= (state.definitionRetries[request.key] or 0) then
            table.insert(lookupRequests, request)
        end
        checkpoint()
    end
    resolveDefinitionBatch(lookupRequests, utility, pending, checkpoint)
    if not state.alive then return end
    -- Flush successful native lookups before attempting any fallback module.
    refresh(true)
    local budget = 24
    for collection, group in pairs(pending) do
        local cursor = definitionCursor(collection, group.category, checkpoint)
        local visited = 0
        local function satisfied()
            for _, request in ipairs(group.requests) do if not Core.definitionReady(state.catalog, request) then return false end end
            return true
        end
        while state.alive and budget > 0 and visited < 256 and #cursor.stack > 0 and not satisfied() do
            local node = table.remove(cursor.stack); local item = node.item
            if not cursor.seen[item] then
                cursor.seen[item] = true; visited += 1
                local children = item:GetChildren()
                for index = #children, 1, -1 do
                    local child = children[index]
                    table.insert(cursor.stack, {item = child, category = Core.catalogCategory(child.Name) or node.category})
                end
                if item:IsA("ModuleScript") then
                    local cached = state.definitionModules[item]
                    if not cached or (cached.failed and os.clock() >= cached.retryAt) then
                        budget -= 1
                        local entries = {{module = item, category = node.category, collection = collection}}
                        loadCatalogModules(entries, false, function(entry, value)
                            state.definitionModules[item] = {value = value, catalogs = {}}
                        end, checkpoint)
                        cached = state.definitionModules[item]
                        if not cached then
                            cached = {failed = true, retryAt = os.clock() + 60}; state.definitionModules[item] = cached
                        end
                    end
                    if cached.value and cached.catalogs[collection] ~= cursor.generation then
                        state.catalogApplying = true; state.inputGeneration = (state.inputGeneration or 0) + 1
                        local report = Core.ingestCatalog(state.catalog, cached.value, item.Name, node.category,
                            {Collection = collection == "Items" and "Items" or nil, Checkpoint = checkpoint})
                        if report.truncated then state.catalogLastFailure = item:GetFullName() .. " | Tabel definisi terpotong" end
                        cached.catalogs[collection] = not report.truncated and cursor.generation or nil
                        state.catalogApplying = false; state.inputGeneration += 1
                    end
                end
            end
            checkpoint()
        end
        cursor.finished = #cursor.stack == 0
        for _, request in ipairs(group.requests) do
            if Core.definitionReady(state.catalog, request) then state.definitionRetries[request.key] = nil
            else
                state.definitionRetries[request.key] = os.clock() + (cursor.finished and 60 or 1)
            end
        end
        if not state.alive then return end
    end
    state.catalogReady = state.catalogLabelsReady == true
    local nextRetry
    for _, request in ipairs(state.definitionRequests or {}) do
        if not Core.definitionReady(state.catalog, request) then
            state.catalogReady = false
            nextRetry = math.min(nextRetry or math.huge, state.definitionRetries[request.key] or os.clock())
        end
    end
    if nextRetry or not state.catalogLabelsReady then
        definitionWake(math.max(1, nextRetry and nextRetry - os.clock() or 30))
    end
end

local function buildCatalog()
    if not state.alive or state.catalogBuilding then return false end
    state.catalogBuilding = true
    state.inputGeneration = (state.inputGeneration or 0) + 1
    state.catalogReady = false; state.catalogStarted = os.clock(); state.catalogFinished = nil
    state.catalogModules = 0; state.catalogFailures = 0; state.catalogLabelFailures = 0
    state.catalogError = nil; state.catalogLastFailure = nil
    local ok, err = pcall(scanCatalog)
    state.catalogBuilding = false; state.catalogApplying = false
    state.inputGeneration = (state.inputGeneration or 0) + 1
    if not state.alive then return false end
    state.catalogFinished = os.clock(); state.catalogModule = nil
    state.catalogPhase = ok and (state.catalogReady and "Selesai" or "ID milik akun") or "Gagal"
    if not ok then
        state.catalogReady = false; state.catalogError = tostring(err)
        state.lastError = tostring(err)
    end
    updateCatalogView(true)
    refresh(true)
end
state.ResolveDefinitions = buildCatalog
local function findReplionModule()
    local packages = ReplicatedStorage:FindFirstChild("Packages")
    if not packages then return nil end
    local index = packages:FindFirstChild("_Index")
    local preferred = index and index:FindFirstChild(CONFIG.ReplionPackage)
    local preferredModule = preferred and (preferred:FindFirstChild("replion") or preferred:FindFirstChild("Replion"))
    if preferredModule and preferredModule:IsA("ModuleScript") then return preferredModule end
    local direct = packages:FindFirstChild("Replion") or packages:FindFirstChild("replion")
    if direct and direct:IsA("ModuleScript") then return direct end
    if index then
        for _, package in ipairs(index:GetChildren()) do
            if package.Name:lower():find("replion", 1, true) then
                local module = package:FindFirstChild("replion") or package:FindFirstChild("Replion")
                if module and module:IsA("ModuleScript") then return module end
            end
        end
    end
    return nil
end
local function startInventoryObserver()
    if not CONFIG.ObserveInventoryEvents then return end
    local hooked = setmetatable({}, { __mode = "k" })
    local supported = { Added = true, Removed = true, Set = true, Update = true, ArrayUpdate = true }
    local function hook(instance)
        if hooked[instance] or not supported[instance.Name] or not instance:IsA("RemoteEvent") then return end
        local folder = instance.Parent
        if not folder or folder.Name ~= "Remotes" or not folder.Parent
            or folder.Parent.Name:lower() ~= "replion" then return end
        local module = findReplionModule()
        if module and module.Parent.Name ~= "Packages" and folder.Parent ~= module then return end
        if state.remoteFolder and folder ~= state.remoteFolder then return end
        state.remoteFolder = folder; state.remotePath = folder:GetFullName()
        hooked[instance] = true; state.remoteCount = state.remoteCount + 1
        connect(instance.OnClientEvent, function(...)
            if not state.alive then return end
            local args = table.pack(...)
            local options = { MaxNodes = CONFIG.MaxInventoryNodes, LocalUserId = player.UserId, PersonalChannels = CONFIG.ReplionChannels,
                DeferCompleteBag = true }
            local equipOk, equipError = pcall(Core.observeEquipment, state.equipmentObserved, instance.Name, args, options)
            if not equipOk then state.equipmentError = tostring(equipError) end
            local previousEquipEvents = state.lastEquipmentEvents or 0
            local equipmentRevision = state.equipmentObserved.revision or state.equipmentObserved.accepted
            local equipmentChanged = equipmentRevision ~= previousEquipEvents
            state.lastEquipmentEvents = equipmentRevision
            local ok, changed
            if state.catalogReady then
                ok, changed = pcall(Core.observeBag, state.observed, state.bag, instance.Name, args, options, state.catalog)
            else ok, changed = pcall(Core.observe, state.observed, instance.Name, args, options) end
            if ok and (changed or equipmentChanged) then
                -- Direct source notifications provide precise paths. Fallback events
                -- cannot safely infer array positions, so invalidate the collection.
                if not state.replion then state.captureReset = true end
                invalidateRead()
            end
            if not ok then
                state.observed.rejected = state.observed.rejected + 1; state.observed.lastError = tostring(changed)
            elseif (changed or equipmentChanged) and not state.paused and not state.queued then
                state.queued = true
                spawnTask(function()
                    task.wait(0.15); state.queued = false
                    if state.alive and not state.paused then refresh() end
                end)
            end
        end)
    end
    connect(ReplicatedStorage.DescendantAdded, hook)
    -- Most sessions expose the exact folder already. Retain discovery fallback
    -- for late/alternate module layouts without allocating all descendants.
    local module = findReplionModule()
    local folder = module and module:FindFirstChild("Remotes")
    if folder then
        for _, instance in ipairs(folder:GetChildren()) do hook(instance) end
    else
        -- Preserve alternate layouts only as a slow recovery cursor. Discovery
        -- never walks the whole tree synchronously during initial execution.
        spawnTask(function()
            local stack,checkpoint={ReplicatedStorage},workCheckpoint()
            while #stack>0 and state.alive and not state.remoteFolder do
                if not state.paused then
                    local foundModule=findReplionModule();local exact=foundModule and foundModule:FindFirstChild("Remotes")
                    if exact then for _,remote in ipairs(exact:GetChildren()) do hook(remote) end end
                    local budget=0
                    while #stack>0 and budget<128 and state.alive and not state.remoteFolder do
                        local node=table.remove(stack);hook(node);checkpoint();budget+=1
                        for _,child in ipairs(node:GetChildren()) do table.insert(stack,child) end
                    end
                end
                if #stack>0 and not state.remoteFolder then task.wait(10) end
            end
            if state.remoteFolder then for _,remote in ipairs(state.remoteFolder:GetChildren()) do hook(remote) end end
        end)
    end
end
discoverClient = function()
    if state.discovering then return false end
    state.discovering = true; state.discoveryNotes = {}
    status("Membaca snapshot tas dari module game...")
    local modules, seenModules = {}, {}
    local function add(module)
        if module and module:IsA("ModuleScript") and not seenModules[module] then
            seenModules[module] = true; table.insert(modules, module)
        end
    end
    local packages = ReplicatedStorage:FindFirstChild("Packages")
    if packages then add(packages:FindFirstChild("Replion") or packages:FindFirstChild("replion")) end
    local canonical = findReplionModule(); add(canonical)
    if canonical then add(canonical:FindFirstChild("Client") or canonical:FindFirstChild("client")) end
    if #modules == 0 then
        state.moduleError = "Packages.Replion belum tersedia"; state.discovering = false; return false
    end
    local seenClients = {}; for _, entry in ipairs(state.clients) do seenClients[entry.client] = true end
    local loaders = Core.requireLoaders(require, env.getrenv or getrenv)
    for _, module in ipairs(modules) do
        for _, loader in ipairs(loaders) do
            local ok, value = boundedRequire(module, loader.call, CONFIG.ReplionRequireTimeout)
            if not state.alive then state.discovering = false; return false end
            local client = ok and Core.resolveClient(value)
            local label = module:GetFullName() .. " / " .. loader.name
            if client then
                if not seenClients[client] then
                    seenClients[client] = true
                    local entry = {client = client, label = label, added = {}}
                    table.insert(state.clients, entry)
                    if type(client.OnReplionAdded) == "function" then
                        local function added(replion)
                            if type(replion) == "table" and type(replion.Data) == "table" then
                                local count = 0; for _ in pairs(entry.added) do count = count + 1 end
                                if count < 64 then entry.added[replion] = true end
                                if state.alive and not state.paused then invalidateRead(); refresh() end
                            end
                        end
                        local connected, connection = pcall(client.OnReplionAdded, client, added)
                        if not connected then connected, connection = pcall(client.OnReplionAdded, added) end
                        if connected and connection then table.insert(state.connections, connection) end
                    end
                end
                state.client = client; state.modulePath = module:GetFullName(); state.moduleError = nil
                table.insert(state.discoveryNotes, "OK client: " .. label)
            else
                table.insert(state.discoveryNotes, "Gagal client: " .. label .. " | " .. tostring(ok and "Tidak ada API Client" or value))
            end
        end
    end
    state.discovering = false
    if #state.clients == 0 then state.moduleError = "Tidak ada Client Replion yang dapat dibaca; lihat percobaan module di Info." end
    return #state.clients > 0
end

-- In-memory controls and exports. No GUI, clipboard, local log file, or hook.
state.GetSnapshot = function() return state.snapshot end
state.ExportJson = function()
    if not state.snapshot then return nil, "Belum ada snapshot" end
    return HttpService:JSONEncode({ schema = "renn-inventory/v1", userId = player.UserId, username = player.Name,
        source = state.source, capturedAt = state.capturedAt, inventory = state.snapshot })
end
state.Refresh = function() refresh(true) end
-- Website policy; player lookup runs only while Auto Trade is enabled.
do
    local policy = {enabled = false, status = "Auto Trade nonaktif", completed = {}, cursor = 1}
    state.automation = policy
    state.SetAutomation = function(value)
        if type(value) ~= "table" or policy.version == value.version then return end
        if state.autoTrade then state.StopAutoTrade("Konfigurasi Auto Trade berubah dari website") end
        policy.version, policy.enabled = value.version, value.enabled == true
        policy.targets = type(value.targets) == "table" and value.targets or {}
        policy.items = type(value.items) == "table" and value.items or {}
        policy.completed, policy.cursor, policy.running = {}, 1, nil
        policy.status = policy.enabled and "Menunggu username target masuk server" or "Auto Trade nonaktif"
    end
    spawnTask(function()
        while state.alive do
            if policy.enabled then
                if policy.running and state.autoTrade ~= policy.running then
                    local finished = policy.running
                    policy.running = nil
                    if finished.success then
                        policy.completed[policy.cursor] = true; policy.cursor = policy.cursor + 1
                        policy.status = "Pengiriman target selesai"
                        if policy.cursor > #policy.targets then
                            policy.enabled = false; policy.status = "Seluruh target selesai; Auto Trade nonaktif"
                            policy.finishedVersion = policy.version
                        end
                    else
                        policy.enabled = false; policy.status = state.tradeMessage or "Trade dihentikan; periksa hasil sebelum memulai kembali"
                        policy.finishedVersion = policy.version
                    end
                end
                if policy.enabled and not state.autoTrade and not policy.running then
                    local wanted = policy.targets[policy.cursor]
                    if type(wanted) ~= "string" then
                        policy.enabled = false; policy.status = "Username target tidak valid"; policy.finishedVersion = policy.version
                    else
                        local target
                        -- Never resolve arbitrary IDs, DisplayName, or a foreign server.
                        for _, candidate in ipairs(Players:GetPlayers()) do
                            if candidate ~= player and candidate.Name:lower() == wanted:lower() then target = candidate; break end
                        end
                        if target then
                            local accepted, reason = state.StartAutoTrade(target.UserId, policy.items)
                            if accepted then policy.running = state.autoTrade; policy.status = "Mengirim ke " .. target.Name
                            else policy.enabled = false; policy.status = tostring(reason); policy.finishedVersion = policy.version end
                        else policy.status = "Menunggu " .. wanted .. " masuk server" end
                    end
                end
            end
            task.wait(10)
        end
    end)
end

-- A website allocation uses the existing verified native trade engine.
do
    local job, cache, order = nil, {}, {}
    local function amounts(values)
        local result = {}
        for key, quantity in pairs(values or {}) do table.insert(result, {key = key, quantity = quantity}) end
        table.sort(result, function(a, b) return a.key < b.key end)
        return result
    end
    local function progress(record, ctx, terminal, reason)
        local unknown = {}
        if terminal and ctx.confirmRequested and not ctx.batchVerified then
            for _, slot in ipairs(ctx.unconfirmedSlots or {}) do unknown[slot.key] = (unknown[slot.key] or 0) + 1 end
        end
        record.report.sent = Core.tradeReportedAmounts(ctx.sentByKey,record.items)
        record.report.proof = (ctx.finished or 0) > 0 and "serverConfirmedWithLocalUnitDelta" or nil
        record.report.uncertain = Core.tradeReportedAmounts(unknown,record.items)
        record.report.status = terminal and (next(unknown) and "uncertain" or ctx.success and "success" or "failed") or "processing"
        record.report.message = reason or state.tradeMessage or "Mengirim item"
        record.report.stockRevision = state.tradeStockRevision or 0
    end
    state.NotifyTradeFinished = function(ctx, reason)
        if job and job.ctx == ctx then progress(job, ctx, true, reason); job.done = true; job.ctx = nil end
    end
    state.SetTradeTask = function(value)
        if type(value) ~= "table" or type(value.id) ~= "string" then return end
        if value.phase == "cancel" then
            local record = cache[value.id]
            if record and record.ctx and state.autoTrade == record.ctx then state.StopAutoTrade("Dihentikan dari website") end
            if record and record.report and (not record.done or record.phase == "probe") then record.done = true; record.acknowledged = false; record.report.status = "stopped"; record.report.message = "Dihentikan pengguna" end
            if record and record.report then job = record end
            return
        end
        if cache[value.id] then if cache[value.id].report then job = cache[value.id] end; return end
        if job and not job.done and job.phase == "send" then return end
        if job and job.done then cache[job.id] = {done = true} end
        local record = {id = value.id, phase = value.phase, target = value.target, items = value.items, report = {id = value.id, sent = {}, uncertain = {}, status = "processing", message = "Memeriksa stok aktual"}}
        job = record; cache[value.id] = record; table.insert(order, value.id)
        if #order > 64 then cache[table.remove(order, 1)] = nil end
        if (value.phase == "probe" or value.phase == "send") and type(value.target) == "string"
            and type(player.Name) == "string" and value.target:lower() == player.Name:lower() then
            record.done = true; record.report.status = "skipped"
            record.report.message = "Dilewati: akun ini adalah penerima; tidak mengirim ke diri sendiri"
            return
        end
        if value.phase == "probe" then
            spawnTask(function()
                local ok, stocks, reason = pcall(state.ReadTradeStock, value.items)
                if job ~= record or record.done then return end
                record.report.status = ok and stocks and "ready" or "failed"
                record.report.stocks = ok and stocks or nil
                record.report.message = ok and stocks and "Stok aktual diperiksa" or tostring(ok and reason or stocks)
                record.done = true
            end)
        elseif value.phase == "send" then record.report.message = "Menunggu " .. tostring(value.target) .. " masuk server"
        else record.done = true; record.report.status = "failed"; record.report.message = "Perintah pengiriman tidak valid" end
    end
    state.TradeReport = function()
        if job and job.ctx and not job.done then progress(job, job.ctx, false) end
        return job and not job.acknowledged and job.report or nil
    end
    state.AcknowledgeTradeTask = function(id) if job and job.done and job.id == id then job.acknowledged = true end end
    state.WebTradeActive = function() return job ~= nil and not job.done and job.phase == "send" end
    state.WebTradeStatus = function() return job and job.report.message or nil end
    spawnTask(function()
        local nextLookup = 0
        while state.alive do
            if job and not job.done and job.phase == "send" then
                local record = job
                if record.ctx then
                    if state.autoTrade ~= record.ctx then progress(record, record.ctx, true, state.tradeMessage); record.done = true; record.ctx = nil end
                elseif os.clock() >= nextLookup then
                    nextLookup = os.clock() + 10
                    local target
                    for _, candidate in ipairs(Players:GetPlayers()) do
                        if candidate ~= player and type(record.target) == "string" and candidate.Name:lower() == record.target:lower() then target = candidate; break end
                    end
                    if target then
                        if state.autoTrade or state.automation.enabled then
                            record.done = true; record.report.status = "failed"; record.report.message = "Akun sedang menjalankan trade lain"
                        else
                            local accepted, reason = state.StartAutoTrade(target.UserId, record.items)
                            if accepted then
                                record.ctx = state.autoTrade; record.report.message = "Mengirim ke " .. target.Name
                                -- task.spawn may complete a rejected invitation before StartAutoTrade returns.
                                if not record.ctx and state.lastTradeOutcome then record.ctx = state.lastTradeOutcome; progress(record, record.ctx, true, state.tradeMessage); record.done = true; record.ctx = nil end
                            else record.done = true; record.report.status = "failed"; record.report.message = tostring(reason) end
                        end
                    end
                end
            end
            task.wait(job and not job.done and 1 or 10)
        end
    end)
end

-- Included by tools/build-rennstats.mjs; not a second collector entrypoint.
do
    local config = type(env.RENNSTATS_CONFIG) == "table" and env.RENNSTATS_CONFIG or {}
    local url = tostring(config.Url or "https://rennstats.rennhsg.my.id"):gsub("/+$", "")
    local key = tostring(env._rennkey or config.Key or "")
    env._rennkey = nil
    env.RENNSTATS_CONFIG = nil
    local requestFn = env.request or env.http_request or request or http_request
        or (syn and syn.request) or (http and http.request) or (fluxus and fluxus.request)
    local session = HttpService:GenerateGUID(false)
    state.fishingRunId=session
    local upload, registered, lastVersion, lastFull, failures, initialComplete = nil, false, nil, 0, 0, false
    local lastTradeStockRevision = 0
    local previousReport, reportRevision, supportsDelta = nil, 0, false
    local lastReconcile = 0
    local reportBudget = Core.workCheckpoint(task.wait, os.clock, 0.002)
    local function reportCheckpoint() (state.sharedCheckpoint or reportBudget)() end
    local seenCommands, receipts, acknowledged = {}, {}, {}
    state.transport = {status = "Menunggu konfigurasi", sentBytes = 0, failures = 0}
    state.DataReady = function()
        local snapshot = state.snapshot
        return state.catalogReady and snapshot ~= nil
            and snapshot.partial == false and snapshot.truncated ~= true and snapshot.mappingComplete == true
    end
    state.PublishReady = function()
        local snapshot = state.snapshot
        return (state.catalogReady or state.catalogLabelsReady) and not state.catalogApplying and snapshot ~= nil
            and snapshot.partial == false and snapshot.truncated ~= true
    end
    local function post(payload, timeout)
        if not state.alive then error("Collector ditutup", 0) end
        state.transport.httpStatus = nil
        payload.userId, payload.session = player.UserId, session
        payload.tradeStockRevision = state.tradeStockRevision or 0
        local body = HttpService:JSONEncode(payload)
        local response = requestFn({Url = url .. "/api.php", Method = "POST", Timeout = timeout or 15,
            Headers = {["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. key}, Body = body})
        if type(response) ~= "table" then error("Respons HTTP kosong", 0) end
        local code = tonumber(response.StatusCode or response.Status or response.status_code)
        state.transport.httpStatus = code
        if code ~= 200 then
            local decoded, failure = pcall(HttpService.JSONDecode, HttpService, response.Body or response.body or "")
            local detail = decoded and type(failure) == "table" and type(failure.error) == "string" and failure.error or nil
            state.transport.serverRevision = decoded and type(failure) == "table" and tonumber(failure.revision) or nil
            if detail then detail = detail:gsub(key:gsub("(%W)", "%%%1"), "[key]"):gsub("[%c]", " "):sub(1, 240) end
            error("HTTP " .. tostring(code or "unknown") .. (detail and (": " .. detail) or ""), 0)
        end
        local result = HttpService:JSONDecode(response.Body or response.body or "")
        if type(result) ~= "table" or result.ok ~= true then error("Web menolak laporan: " .. tostring(result and result.error), 0) end
        state.transport.sentBytes = state.transport.sentBytes + #body
        return result
    end
    local function command(command)
        if type(command) ~= "table" or type(command.id) ~= "string" or seenCommands[command.id] then return end
        seenCommands[command.id] = true -- Mark before running: mutations are never repeated after a lost response.
        local receipt = {id = command.id, ok = false, message = "Perintah tidak dikenal"}
        local ok, err = pcall(function()
            local args = type(command.args) == "table" and command.args or {}
            if command.action == "refresh" then state.Refresh(); receipt.ok = true; receipt.message = "Pembacaan dijadwalkan"
            elseif command.action == "pause" then state.paused = args.paused == true; receipt.ok = true; receipt.message = state.paused and "Pembacaan dijeda" or "Pembacaan aktif"; if not state.paused then state.Refresh() end
            elseif command.action == "diagnostics" then receipt.ok = true; receipt.message = state.GetDiagnostics()
            elseif command.action == "trade_stop" then
                state.automation.enabled = false; state.automation.status = "Dihentikan dari website"
                state.StopAutoTrade("Dihentikan dari website"); receipt.ok = true; receipt.message = state.tradeMessage
            elseif command.action == "trade_plan" or command.action == "trade_start" then
                if state.autoTrade then receipt.message = "Trade masih aktif; hentikan terlebih dahulu"; return end
                local target, selection = tonumber(args.targetUserId), args.items
                if type(selection) ~= "table" then receipt.message = "Pilihan item kosong"; return end
                local accepted, result
                if command.action == "trade_plan" and type(args.username) == "string" then
                    result = Core.tradePlan(state.currentInventory or {}, state.catalog, selection, {localUserId = player.UserId,
                        targetUserId = player.UserId + 1, fullSnapshot = not state.partial, catalogReady = state.catalogReady, itemCatalogReady = state.catalogLabelsReady})
                    if result then
                        result.targetName = args.username; result.batches = Core.tradeExecutionBatches(result)
                        accepted = true; state.tradeMessage = "Stok valid untuk " .. args.username .. "; identitas penerima diverifikasi saat masuk server"
                    else accepted = false; result = "Pilihan/stok belum dapat divalidasi" end
                elseif command.action == "trade_plan" then accepted, result = state.PrepareTrade(target, selection)
                else accepted, result = state.StartAutoTrade(target, selection) end
                receipt.ok = accepted == true
                receipt.message = receipt.ok and state.tradeMessage or tostring(result)
                if receipt.ok then receipt.plan = {total = result.total, batches = #result.batches, targetName = result.targetName} end
            elseif command.action == "inventory_gui" then
                local node = playerGui
                if type(args.path) ~= "table" or #args.path > 20 then receipt.message = "Path tas tidak valid"; return end
                for _, name in ipairs(args.path) do node = node and node:FindFirstChild(tostring(name)) end
                receipt.ok, receipt.message = state.SelectInventoryGui(node)
                if receipt.ok then state.Refresh() end
            elseif command.action == "inventory_pick" then
                receipt.ok, receipt.message = state.PickInventoryAtPosition(tonumber(args.x), tonumber(args.y))
                if receipt.ok then state.Refresh() end
            end
        end)
        if not ok then receipt.ok = false; receipt.message = tostring(err) end
        receipts[command.id] = receipt
    end
    local function consume(result)
        for _, id in ipairs(result.acknowledged or {}) do receipts[id] = nil; acknowledged[id] = true end
        for _, entry in ipairs(result.commands or {}) do command(entry) end
        if result.settings then
            CONFIG.RefreshSeconds = math.clamp(tonumber(result.settings.readSeconds) or 60, 60, 120)
        end
        if result.automation then state.SetAutomation(result.automation) end
        if result.tradeTaskAck then state.AcknowledgeTradeTask(result.tradeTaskAck) end
        if result.tradeTask then state.SetTradeTask(result.tradeTask) end
    end
    local function metadata(snapshot)
        local ctx = state.autoTrade
        return {username = player.Name, displayName = player.DisplayName, placeId = game.PlaceId, gameId = game.GameId,
            jobId = game.JobId, version = "rennstats/1.9", source = state.source, status = state.status,
            paused = state.paused, lastError = state.lastError, catalogReady = state.catalogReady,
            playerStats = snapshot and snapshot.playerStats or state.playerStats,
            equipment = snapshot and snapshot.equipment or {},
            trade = {active = ctx ~= nil, message = state.tradeMessage, targetUserId = ctx and ctx.target.UserId,
                totalBatches = ctx and #ctx.batches, batch = ctx and ctx.batchIndex, finished = ctx and ctx.finished,
                phase = ctx and ctx.phase, result = state.tradeJournal and state.tradeJournal.completion},
            diagnostics = state.GetDiagnostics()}
    end
    local function briefMetadata()
        local snapshot = state.snapshot
        return {username = player.Name, displayName = player.DisplayName, placeId = game.PlaceId,
            gameId = game.GameId, jobId = game.JobId, version = "rennstats/1.9",
            playerStats = snapshot and snapshot.playerStats or state.playerStats, equipment = snapshot and snapshot.equipment or {},
            progress = {phase = not snapshot and "Mengambil inventori" or state.DataReady() and "Siap" or "Memetakan informasi item",
                complete = state.DataReady()}}
    end
    local lastControl = 0
    local function pollControl()
        local pending = {}
        for _, value in pairs(receipts) do table.insert(pending, value) end
        local ctx, policy = state.autoTrade, state.automation
        consume(post({action = "control", receipts = pending, metadata = briefMetadata(), automationVersion = policy.finishedVersion,
            tradeReport = state.TradeReport(), tradeStockRevision = state.tradeStockRevision or 0,
            control = {paused = state.paused, enabled = policy.enabled or state.WebTradeActive(), status = state.WebTradeActive() and state.WebTradeStatus() or policy.status, target = policy.targets and policy.targets[policy.cursor],
                version = policy.version, active = ctx ~= nil, message = state.tradeMessage, batch = ctx and ctx.batchIndex, finished = ctx and ctx.finished}}))
        lastControl = os.clock()
    end
    state.HandleWebCommand = command
    state.WebReceipts = receipts
    local closeReader = state.Close
    state.Close = function()
        if not state.alive then return end
        state.automation.enabled = false
        state.StopAutoTrade("Collector ditutup")
        if registered then pcall(post, {action = "goodbye"}, 5); registered = false end
        closeReader()
    end
    spawnTask(function()
        if not url:match("^https://[^/]+") or key == "" or type(requestFn) ~= "function" then
            state.transport.status = "Atur URL HTTPS dan Key dari website; executor memerlukan request/http_request"
            return
        end
        while state.alive do
            local ok, err = pcall(function()
                if not registered then
                    local hello = post({action = "hello", metadata = briefMetadata()})
                    supportsDelta = hello.inventoryDelta == 1
                    consume(hello); registered = true
                end
                pollControl()
                local progressDue = not initialComplete and (lastVersion == nil or state.revision ~= lastVersion or state.DataReady())
                local tradeDue = (state.tradeStockRevision or 0) > lastTradeStockRevision
                local changedDue = supportsDelta and state.revision ~= lastVersion
                if (upload or state.PublishReady() and (progressDue or tradeDue or changedDue or os.clock() - lastFull >= 600)) and (not state.paused or tradeDue) then
                    if not upload then
                        if state.busy and not (state.snapshot and state.snapshot.isolated) then return end
                        local snapshot, revision, generation = state.snapshot, state.revision, state.inputGeneration or 0
                        if state.completedRead and not snapshot.isolated and state.completedRead.generation ~= generation then state.Refresh(); return end
                        local completed = state.completedRead
                        local isolated = snapshot.isolated and completed and completed.isolated and completed.snapshot == snapshot
                        if snapshot.isolated and not isolated then return end
                        if (snapshot.tradeStockRevision or 0) < (state.tradeStockRevision or 0) then state.Refresh(); return end
                        local choices = state.TradeChoices(isolated and completed or nil)
                        -- Module discovery may yield; a report must come from one completed read.
                        if not isolated and (state.busy or state.snapshot ~= snapshot or state.revision ~= revision
                            or generation ~= (state.inputGeneration or 0) or not state.PublishReady()) then return end
                        local inventory, available = Core.publishInventory(snapshot, choices, reportCheckpoint)
                        if not inventory then return end
                        if not isolated and (state.busy or state.snapshot ~= snapshot or state.revision ~= revision
                            or generation ~= (state.inputGeneration or 0) or not state.PublishReady()) then return end
                        local encodeStarted = os.clock()
                        local report = {inventory = inventory, choices = available, fishing=snapshot.fishing, metadata = metadata(snapshot), revision=reportRevision+1,
                            capturedAt = snapshot.capturedAt or state.capturedAt, tradeStockRevision = snapshot.tradeStockRevision or 0, schema = "rennstats/v1"}
                        local full = not previousReport or not supportsDelta or os.clock() - lastReconcile >= 600
                        local payload = full and report or Core.reportDelta(previousReport,report,reportCheckpoint)
                        local chunks, bytes = Core.jsonChunks(payload,function(value) return HttpService:JSONEncode(value) end,reportCheckpoint)
                        state.reportEncodeMs = (os.clock() - encodeStarted) * 1000; state.reportBytes = bytes
                        upload = {id = HttpService:GenerateGUID(false), chunks = chunks, version = revision, part = 1,
                            total = #chunks, report=report, full=full, complete = inventory.mappingComplete == true, stockRevision = snapshot.tradeStockRevision or 0}
                    end
                    while state.alive and upload.part <= upload.total do
                        if os.clock() - lastControl >= 5 then pollControl() end
                        local part = upload.part
                        consume(post({action = "upload", uploadId = upload.id, part = part, total = upload.total,
                            chunk = upload.chunks[part]}))
                        upload.chunks[part] = nil
                        upload.part = part + 1
                        task.wait() -- Let inventory/trade events run between chunks.
                    end
                    if state.alive then
                        local committed = post({action = "commit", uploadId = upload.id, total = upload.total})
                        consume(committed)
                        lastVersion, lastFull = upload.version, os.clock()
                        lastTradeStockRevision = upload.stockRevision or 0
                        previousReport = upload.report; reportRevision = upload.report.revision
                        if supportsDelta and committed.inventoryRevision and committed.inventoryRevision ~= reportRevision then
                            previousReport = nil; lastVersion = nil
                        end
                        if upload.full then lastReconcile = os.clock() end
                        initialComplete = initialComplete or upload.complete; upload = nil
                    end
                end
                failures = 0; state.transport.status = state.DataReady() and "Terhubung" or "Terhubung; inventori sedang dimuat"
                state.transport.lastSentAt = os.time()
                -- Commands already acknowledged by the server are safe to forget locally.
                for id in pairs(acknowledged) do seenCommands[id] = nil; acknowledged[id] = nil end
            end)
            if not state.alive then return end
            if not ok then
                failures = math.min(failures + 1, 6); state.transport.failures = state.transport.failures + 1
                state.transport.status = tostring(err)
                state.lastError = tostring(err)
                if state.transport.httpStatus == 412 then
                    previousReport, upload, lastVersion = nil, nil, nil
                    reportRevision = math.max(reportRevision, state.transport.serverRevision or 0)
                    initialComplete = false
                end
                if state.transport.httpStatus == 409 then state.Close(); return end
                if state.transport.httpStatus == 410 then
                    registered, upload, lastVersion, initialComplete = false, nil, nil, false
                    previousReport, reportRevision = nil, 0
                    state.automation.enabled = false
                    state.StopAutoTrade("Sesi web kedaluwarsa; Auto Trade dihentikan")
                end
                if state.transport.httpStatus == 401 or state.transport.httpStatus == 403 then
                    state.Close(); return
                end
            end
            task.wait(math.min(60, 10 * 2 ^ failures))
        end
    end)
end

spawnTask(function()
    startInventoryObserver()
    discoverClient()
    refresh(true)
    buildCatalog()
end)
spawnTask(function()
    local nextDiscover, nextCatalog = os.clock() + 10, os.clock() + 30
    while state.alive do
        task.wait(CONFIG.RefreshSeconds)
        if not state.alive then return end
        if not state.client and os.clock() >= nextDiscover then
            discoverClient(); nextDiscover = os.clock() + 10
        end
        if os.clock() >= nextCatalog and (not state.catalogLabelsReady or state.catalogError
            or (state.snapshot and (state.snapshot.unresolved > 0 or state.snapshot.missingIcons > 0))) then
            buildCatalog(); nextCatalog = os.clock() + 30
        end
        if not state.paused then refresh() end
    end
end)
return state
