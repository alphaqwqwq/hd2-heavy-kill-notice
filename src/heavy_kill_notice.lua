-- Heavy Kill Notice -- broadcast a chat line to the whole squad when a Helldiver kills a
-- heavy-armour enemy: "<who> killed <heavy unit> with <weapon>".
--
-- Route A: a standalone addon. It borrows three proven methods:
--   * detection      : HD2Runtime 0.28.1 gameplay events (entity_killed) -- the BFV Kill Feedback hook.
--   * player names   : the game's persona roster, *(game.dll + 0x347ced8), one 0xC0-byte record per
--                      slot (peer id at +0, callsign at +8, NUL-terminated before +0x89) -- the
--                      DeathSourceNotice method.
--   * weapon name    : the killer's held weapon through the wielder hash map (DeathSourceNotice),
--                      resolved against a 502-entry type-name catalog (weapon + enemy, EN/ZH).
--   * the chat line  : the game's own native team-chat sender, game.dll + 0x1097560,
--                      send(*(game + 0x347cef0) + 0xC418, 0, text) -- the "notice" method.
--
-- Everything is read-only on the game side except the one native chat call, which is the same call
-- the game makes when you press Enter. No hooks, no code writes. Reads fail soft (ReadProcessMemory).
-- The native call is only made after its code signature is verified.
--
-- Addresses are pinned to game.dll build 25480438 / stamp 6AB3B43F. On any other build the mod
-- disables itself and says so. Restart the game to remove it entirely.

local loader = rawget(_G, 'CowboyBingusModLoader')
assert(loader and loader.api == 1, "Heavy Kill Notice requires Bingus Shared Loader API 1")

local hd2 = require('mods/skyeshade/hd2runtime')
local key = 'HeavyKillNoticeMod'
if rawget(_G, key) then return rawget(_G, key) end

local mod = hd2.mod()
local ffi = require('ffi')

-- === generated name catalog: local CATALOG / local HEAVY =======================================
--@CATALOG@

-- === constants (pinned build) ==================================================================
local EXPECT_TIMESTAMP = 0x6AB3B43F
local EXPECT_IMAGE_SIZE = 0x4744000

local SEND_RVA = 0x1097560
local SEND_SIG = "\65\86\65\87\72\129\236\120\4\0\0\72\139\5\158\74\90\1\72\51\196\72\137\132\36\80\4\0\0\128\57\0"

local OFF_CTX      = 0x347CEF0   -- session context pointer
local OFF_ROSTER   = 0x347CED8   -- persona roster pointer
local OFF_CHAT     = 0xC418      -- chat object inside the context
local OFF_LOCAL    = 0xB398      -- local peer (u64)
local OFF_HOST     = 0xB3A8      -- host peer  (u64)

local PERSONA_COUNT = 8
local PERSONA_STRIDE = 0xC0
local CALLSIGN_OFF = 0x89        -- name bytes live at +8 .. +(CALLSIGN_OFF)

-- wielder hash map (DeathSourceNotice profile.wielder)
local W = {
    wielder = 53634080, wielderHash = 48, slots = 96, stride = 464,
    entities = 54968216, entityMap = 15838896, descriptors = 15937304,
    descriptorStride = 24, descriptorEntity = 8,
}

-- damage queue + avatar network map (DeathSourceNotice profile.queue / profile.avatars).
-- The queue holds each pending damage event; its dealer is the entity that dealt the blow,
-- which is the actual weapon (including stratagems and support weapons), for ANY player.
local Q = { global = 55037752, base = 4384, stride = 112, count = 2101536, max = 4096 }
local AV = { entities = 54968216, mapSlots = 15871688, entityBase = 15937312, entityStride = 24, noNetworkId = 32767 }

local clock = 0   -- seconds since load; the heat/queue timers use it
local said = {}
local function diag(key, msg, every)
    every = every or 1
    local n = (said[key] or 0) + 1
    said[key] = n
    if n <= 3 or n % every == 0 then mod:log(msg) end
end

local MAX_TEXT = 512

-- === FFI =======================================================================================
local function make_api()
    if not rawget(_G, 'HeavyKillNoticeFfi') then
        ffi.cdef[[
            void *HKN_GetModuleHandleA(const char *) __asm__("GetModuleHandleA");
            void *HKN_GetCurrentProcess(void) __asm__("GetCurrentProcess");
            int HKN_ReadProcessMemory(void *,const void *,void *,size_t,size_t *) __asm__("ReadProcessMemory");
            short HKN_GetAsyncKeyState(int) __asm__("GetAsyncKeyState");
        ]]
        rawset(_G, 'HeavyKillNoticeFfi', true)
    end
    local k = ffi.load('kernel32')
    local u = ffi.load('user32')
    local process = k.HKN_GetCurrentProcess()
    local api = {}
    function api.key(vk) return tonumber(u.HKN_GetAsyncKeyState(vk)) end
    function api.module(name)
        local p = k.HKN_GetModuleHandleA(name)
        if p == nil then return nil end
        return tonumber(ffi.cast('uintptr_t', p))
    end
    local buf, cnt = ffi.new('uint8_t[?]', 4096), ffi.new('size_t[1]')
    function api.read(a, size)
        if type(a) ~= 'number' or a < 65536 or a >= 0x800000000000 or size < 1 or size > 1048576 then return nil end
        local out = size <= 4096 and buf or ffi.new('uint8_t[?]', size)
        if k.HKN_ReadProcessMemory(process, ffi.cast('const void *', a), out, size, cnt) == 0
            or tonumber(cnt[0]) ~= size then return nil end
        return ffi.string(out, size)
    end
    function api.read_into(a, size, dst)
        if type(a) ~= 'number' or a < 65536 or a >= 0x800000000000 or size < 1 then return false end
        return k.HKN_ReadProcessMemory(process, ffi.cast('const void *', a), dst, size, cnt) ~= 0
            and tonumber(cnt[0]) == size
    end
    return api
end
local mem = make_api()

-- === byte helpers ==============================================================================
local function u32(s, o)
    if type(s) ~= 'string' or o < 0 or #s < o + 4 then return nil end
    local a, b, c, d = s:byte(o + 1, o + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function peer_hex(s, o)
    local lo, hi = u32(s, o), u32(s, o + 4)
    if not lo or not hi or (lo == 0 and hi == 0) then return nil end
    return string.format('%08X%08X', hi, lo)
end
local function pointer_of(s, o)
    local lo, hi = u32(s, o), u32(s, o + 4)
    if not lo or not hi or hi >= 32768 then return nil end
    local n = lo + hi * 4294967296
    return n >= 65536 and n or nil
end
local function mul32(a, b) return (a * (b % 65536) + ((a * math.floor(b / 65536)) % 65536) * 65536) % 4294967296 end

local game = nil
local read = function(a, n) if game and a then return mem.read(a, n) end return nil end
local read_u32 = function(a) return u32(read(a, 4) or nil, 0) end
local read_ptr = function(a) return pointer_of(read(a, 8) or nil, 0) end

local function hex2bytes(h) return (h:gsub('..', function(x) return string.char(tonumber(x, 16)) end)) end
local function at_bytes_ok(addr, bytes)
    local got = read(addr, #bytes)
    return got ~= nil and got == bytes
end

-- === open / verify =============================================================================
local S = { ready = false, reason = nil, weapon_ok = false, send_fn = nil, text_buf = ffi.new('char[?]', MAX_TEXT + 1) }

local function verify()
    local base = mem.module('game.dll')
    if not base then return nil, 'game.dll not loaded' end
    local head = mem.read(base + 0, 4096)
    if not head or head:sub(1, 2) ~= 'MZ' then return nil, 'bad PE header' end
    local pe = u32(head, 60) or 0
    if pe < 64 or pe > 2048 or head:sub(pe + 1, pe + 4) ~= 'PE\0\0' then return nil, 'bad PE offset' end
    local stamp = u32(head, pe + 8)
    local size = u32(head, pe + 0x50)
    if stamp ~= EXPECT_TIMESTAMP or size ~= EXPECT_IMAGE_SIZE then
        return nil, string.format('unsupported build (stamp=%08X size=%X)', stamp or 0, size or 0)
    end
    if mem.read(base + SEND_RVA, #SEND_SIG) ~= SEND_SIG then return nil, 'chat sender signature mismatch' end
    game = base
    S.send_fn = ffi.cast('void (*)(uint64_t,uint64_t,uint64_t)', base + SEND_RVA)
    S.weapon_ok = true
    return true
end

do
    local ok, why = verify()
    if not ok then
        rawset(_G, key, false)
        -- Log via HD2Runtime if it is up; otherwise stay silent (nothing to do at the menu).
        pcall(function() mod:log('heavy kill notice disabled: ' .. tostring(why)) end)
        return false
    end
end

-- === persona roster: peer -> name ==============================================================
local names = {}
local names_at = -1e9
local function refresh_names(now)
    if now - names_at < 2 then return names end
    names_at = now
    local base = read_ptr(game + OFF_ROSTER)
    if not base then return names end
    for slot = 0, PERSONA_COUNT - 1 do
        local rec = read(base + slot * PERSONA_STRIDE, PERSONA_STRIDE)
        if rec and #rec >= CALLSIGN_OFF then
            local p = peer_hex(rec, 0)
            if p then
                local tail = rec:sub(9, CALLSIGN_OFF)
                local stop = tail:find('\0', 1, true)
                if stop and stop > 1 then
                    local name = tail:sub(1, stop - 1)
                    if name ~= '' then names[p] = name end
                end
            end
        end
    end
    return names
end

-- === weapon: the killer's held weapon through the wielder hash map =============================
local function hash_value(manager, offset, id, maxcap)
    if not manager or type(id) ~= 'number' or id <= 0 or id >= 4294967295 then return nil end
    local h = read(manager + offset, 20)
    if not h then return nil end
    local slots = pointer_of(h, 0)
    local cap, empty, mult = u32(h, 8), u32(h, 12), u32(h, 16)
    if not slots or not cap or cap == 0 or cap > maxcap or cap % 2 ~= 0 then return nil end
    local start = mul32(id, mult)
    for i = 0, math.min(cap, 256) - 1 do
        local s = read(slots + ((start + i) % cap) * 8, 8)
        if not s then return nil end
        local k = u32(s, 0)
        if k == id then return u32(s, 4) end
        if k == empty then return nil end
    end
    return nil
end

local function entity_type(id)
    if not S.weapon_ok then return nil end
    local m = read_ptr(game + W.entities)
    if not m then return nil end
    local index = hash_value(m, W.entityMap, id, 65536)
    if not index then return nil end
    local desc = m + W.descriptors + index * W.descriptorStride
    local raw = read(desc, 24)
    if not raw or u32(raw, 8) ~= id then return nil end
    return peer_hex(raw, 0)
end

local function held_weapon(avatar_id)
    if not S.weapon_ok or not avatar_id then return nil end
    local m = read_ptr(game + W.wielder)
    if not m then return nil end
    local index = hash_value(m, W.wielderHash, avatar_id, 65536)
    if not index then return nil end
    local slots = read_ptr(m + W.slots)
    if not slots then return nil end
    local id = read_u32(slots + index * W.stride)
    if not id or id <= 0 then return nil end
    return id
end

local function weapon_name_for(type_hex)
    local e = type_hex and CATALOG[type_hex]
    if e and e.kind2 ~= 'enemy' then return e end
    return nil
end

-- === damage source: the dealer entity from the game's damage queue =============================
-- A network game object id -> entity id, through the avatar network map.
local function network(goid, mgr)
    if not goid or goid == AV.noNetworkId or goid == 0 then return nil end
    mgr = mgr or read_ptr(game + AV.entities)
    if not mgr then return nil end
    local index = hash_value(mgr, AV.mapSlots, goid, 1048576)
    if not index or index >= 1048576 then return nil end
    local e = read_u32(mgr + AV.entityBase + index * AV.entityStride)
    if not e or e <= 0 then return nil end
    return e
end

-- recent damage per victim entity: { type = dealer type hex, t = clock }
-- The whole queue buffer is read, not just its `count` rows: consumed records survive a zero count
-- (DeathSourceNotice's "Read inactive queue slots too" note). Enemy victims are kept, not filtered.
local recent = {}
local net_cache = {}          -- goid -> { type = dealer type hex, t = clock }
local scan_at = -1e9
local prune_at = -1e9
local SCAN_INTERVAL = 0.10
local NET_TTL = 1.0
local SLOW_SCAN = 0.006
local QMAX = Q.max
local QW = Q.stride / 4                       -- 28 u32 per slot
local qbuf = ffi.new('uint8_t[?]', QMAX * Q.stride)
local qwords = ffi.cast('const uint32_t *', qbuf)

local function prune(now)
    if now - prune_at < 5 then return end
    prune_at = now
    for k, v in pairs(recent) do if now - v.t > 5 then recent[k] = nil end end
    for k, v in pairs(net_cache) do if now - v.t > 5 then net_cache[k] = nil end end
end

local function scan_queue()
    if clock - scan_at < SCAN_INTERVAL then return end
    scan_at = clock
    local t0 = os.clock()
    local system = read_ptr(game + Q.global)
    if not system then return end
    if not mem.read_into(system + Q.base, QMAX * Q.stride, qbuf) then return end
    local emgr = S.weapon_ok and read_ptr(game + W.entities) or nil
    local hits = 0
    for i = QMAX - 1, 0, -1 do                 -- reverse: the most recent slot (low index) wins
        local b = i * QW
        local target = qwords[b]
        if target > 0 and target < 0xFFFFFFFE then
            local kind = qwords[b + 1]         -- +4
            if kind <= 12 then
                local goid = qwords[b + 4]     -- +16 dealer goid
                if goid > 0 and goid < 0xFFFFFFFE then
                    local dt
                    local c = net_cache[goid]
                    if c and clock - c.t <= NET_TTL then
                        dt = c.type
                    else
                        local dealer = network(goid, emgr)
                        dt = dealer and entity_type(dealer)
                        if dt then net_cache[goid] = { type = dt, t = clock } end
                    end
                    if dt then recent[target] = { type = dt, t = clock }; hits = hits + 1 end
                end
            end
        end
    end
    prune(clock)
    local cost = os.clock() - t0
    if cost > SLOW_SCAN then
        diag('slow', string.format('heavy kill notice: damage scan slow (%.1f ms, %d rows)', cost * 1000, hits), 20)
    end
    if hits > 0 then diag('queue', 'heavy kill notice: damage scan resolved ' .. hits .. ' dealer rows', 60) end
end

-- The weapon that actually dealt the killing blow to this victim (nil if unknown / too old).
local function weapon_from_damage(entity_id)
    local r = entity_id and recent[entity_id]
    if r and clock - r.t <= 2 then
        local e = CATALOG[r.type]
        if e and e.kind2 ~= 'enemy' then return r.type end
    end
end

-- === chat send =================================================================================
local function is_host()
    local ctx = read_ptr(game + OFF_CTX)
    if not ctx then return false end
    local slo, shi = u32(read(ctx + OFF_LOCAL, 8) or '', 0), u32(read(ctx + OFF_LOCAL, 8) or '', 4)
    local hlo, hhi = u32(read(ctx + OFF_HOST, 8) or '', 0), u32(read(ctx + OFF_HOST, 8) or '', 4)
    if not slo or not hlo then return false end
    if slo == 0 and shi == 0 then return false end
    return slo == hlo and shi == hhi
end

local function raw_send(text)
    local ctx = read_ptr(game + OFF_CTX)
    if not ctx then return false, 'no chat context' end
    local chat = ctx + OFF_CHAT
    local enabled = read_u32(chat)
    if not enabled or enabled % 256 == 0 then return false, 'team text chat unavailable' end
    local n = #text
    if n > MAX_TEXT then n = MAX_TEXT end
    ffi.copy(S.text_buf, text, n)
    S.text_buf[n] = 0
    S.send_fn(chat, 0, tonumber(ffi.cast('uintptr_t', S.text_buf)))
    return true
end

-- === options ===================================================================================
-- Labels/descriptions are bilingual (EN / 中文) on purpose: Mod Options Menu registers option
-- text once at startup and has no runtime relabel, so a language switch for the menu itself is
-- not possible. Showing both keeps every user able to read it. The broadcast language is the
-- separate "Language / 语言" option below.
local options = hd2.options({ id = 'heavy_kill_notice', title = 'Heavy Kill Notice / 重甲击杀播报' })
local enabled = options:toggle({ id = 'enabled', label = 'Enabled / 启用', default = true,
    description = 'Broadcast a chat line when a Helldiver kills a heavy enemy. 潜兵击杀重甲时向全队聊天播报。' })
local chatMode = options:choice({ id = 'chat_mode', label = 'Chat broadcast / 播报方式',
    choices = { 'Smart (host all / client own) / 智能', 'Host only / 仅房主', 'Everyone / 每人', 'Off / 关闭' }, default = 1,
    description = 'Smart: host announces all, a client only its own (no duplicates). 智能：房主播报全部，客机只播报自己的击杀。' })
local lang = options:choice({ id = 'language', label = 'Language / 语言',
    choices = { 'English', '简体中文', 'Bilingual / 双语' }, default = 3,
    description = 'Menu and broadcast language. Bilingual puts both on one line. 菜单与播报语言；双语=中英同一行。' })
local showWeapon = options:toggle({ id = 'show_weapon', label = 'Include weapon / 含武器', default = true,
    description = 'Off: only who killed what. 关闭：只显示「谁 击杀了 什么」。' })
local weaponSource = options:choice({ id = 'weapon_source', label = 'Weapon source / 武器来源',
    choices = { 'Precise only (hide unknown) / 仅精确', 'Precise, else held / 精确否则手持', 'Held only / 仅手持' }, default = 1,
    description = 'Precise = the real killing blow. If not captured, Precise only hides the weapon. 精确=真正造成击杀的武器；抓不到就不显示。' })
local minGap = options:slider({ id = 'gap', label = 'Min gap 0.1s / 最小间隔', min = 5, max = 60, step = 5, default = 10 })
local testKey = options:toggle({ id = 'test_key', label = 'Test key F9 / 测试键', default = false,
    description = 'F9 sends one test line. Troubleshooting only. 仅排障用，平时不需要按键。' })
local countMode = options:choice({ id = 'count_mode', label = 'Kill count / 击杀计数',
    choices = { 'Off / 关', 'Per type / 按种类', 'Per-mission total / 本局总数', 'Both / 两者' }, default = 1,
    description = 'Append this mission tally per killer. 在播报末尾加该击杀者本局的重甲统计；每局重置。' })
local display = options:choice({ id = 'display', label = 'Display / 显示方式',
    choices = { 'Full / 完整', 'Compact / 紧凑', 'Milestones / 里程碑' }, default = 2,
    description = 'Full: one line per kill. Compact: a short line with no verbs (P2 · Charger · EAT-17). Milestones: only announce every N kills, with a bit of flavour. 完整=每次击杀一行；紧凑=去掉动词的短行；里程碑=每 N 杀才播报一次。' })
local milestoneStep = options:slider({ id = 'milestone_step', label = 'Milestone step / 里程碑步长', min = 1, max = 50, step = 1, default = 5,
    description = 'In Milestones mode, announce every N kills (5, 10, 15...). 里程碑模式下每 N 杀播报一次。' })
local nameStyle = options:choice({ id = 'name_style', label = 'Player name / 玩家名',
    choices = { 'Full name / 完整名字', 'P1-P4 / 编号' }, default = 2,
    description = 'P1-P4 uses the in-game player number (short and language-neutral). 编号=P1~P4（游戏内可见，短且不分语言）。' })
local combo = options:toggle({ id = 'combo', label = 'Combo line / 连杀提示', default = true,
    description = 'In Milestones mode, add one flavoured line when a player kills several heavies in a row. 里程碑模式下，短时间连杀重甲时额外冒一句。' })

-- === menu language hot-switch (BFV Kill Feedback's method) =====================================
-- Mod Options Menu registers option specs once and has no relabel API, but it keeps them in a
-- private `state` table. Like BFV Kill Feedback, we find that table through debug.getupvalue and
-- rewrite the label/description/choices of the specs whose id is ours; the menu re-renders at once.
local UI = {
    en = {
        title = 'Heavy Kill Notice',
        enabled = { label = 'Enabled', desc = 'Broadcast a chat line when a Helldiver kills a heavy enemy.' },
        chat_mode = { label = 'Chat broadcast', desc = 'Smart: host announces all, a client only its own (no duplicates).',
            choices = { 'Smart (host: all / client: own)', 'Host only', 'Everyone', 'Off' } },
        language = { label = 'Language', desc = 'Menu and broadcast language. Bilingual puts both on one line.' },
        show_weapon = { label = 'Include weapon', desc = 'Off: only who killed what.' },
        weapon_source = { label = 'Weapon source', desc = 'Precise = the real killing blow; if not captured, hide it.',
            choices = { 'Precise only (hide unknown)', 'Precise, else held', 'Held only' } },
        gap = { label = 'Min gap (0.1s)', desc = 'Minimum seconds between broadcasts (anti-spam).' },
        test_key = { label = 'Test key (F9)', desc = 'F9 sends one test line. Troubleshooting only.' },
        count_mode = { label = 'Kill count', desc = 'Per-mission tally appended to each line.',
            choices = { 'Off', 'Per type', 'Per-mission total', 'Both' } },
        display = { label = 'Display', desc = 'Full: one line per kill. Compact: a short line with no verbs. Milestones: only every N kills.',
            choices = { 'Full', 'Compact', 'Milestones' } },
        milestone_step = { label = 'Milestone step', desc = 'In Milestones mode, announce every N kills (5, 10, 15...).' },
        name_style = { label = 'Player name', desc = 'P1-P4 uses the in-game player number (short and language-neutral).',
            choices = { 'Full name', 'P1-P4' } },
        combo = { label = 'Combo line', desc = 'In Milestones mode, add one flavoured line when a player kills several heavies in a row.' },
    },
    zh = {
        title = '重甲击杀播报',
        enabled = { label = '启用', desc = '潜兵击杀重甲时向全队聊天播报。' },
        chat_mode = { label = '播报方式', desc = '智能：房主播报全部，客机只播报自己的击杀（不重复）。',
            choices = { '智能（房主全部/客机自己）', '仅房主', '每人', '关闭' } },
        language = { label = '语言', desc = '菜单与播报语言；双语=中英同一行。' },
        show_weapon = { label = '含武器', desc = '关闭：只显示「谁 击杀了 什么」。' },
        weapon_source = { label = '武器来源', desc = '精确=真正造成击杀的武器；抓不到就不显示。',
            choices = { '仅精确（抓不到隐藏）', '精确否则手持', '仅手持' } },
        gap = { label = '最小间隔 (0.1s)', desc = '两次播报之间的最小秒数（防刷屏）。' },
        test_key = { label = '测试键 (F9)', desc = '按 F9 发一条测试消息，仅排障用。' },
        count_mode = { label = '击杀计数', desc = '在播报末尾加该击杀者本局的重甲统计。',
            choices = { '关闭', '按种类', '本局总数', '两者' } },
        display = { label = '显示方式', desc = '完整=每次击杀一行；紧凑=去掉动词的短行；里程碑=每 N 杀才播报一次。',
            choices = { '完整', '紧凑', '里程碑' } },
        milestone_step = { label = '里程碑步长', desc = '里程碑模式下每 N 杀播报一次（5、10、15…）。' },
        name_style = { label = '玩家名', desc = '编号=P1~P4（游戏内可见，短且不分语言）。',
            choices = { '完整名字', '编号' } },
        combo = { label = '连杀提示', desc = '里程碑模式下，短时间连杀重甲时额外冒一句。' },
    },
}
local UI_KEYS = { 'enabled', 'chat_mode', 'language', 'show_weapon', 'weapon_source', 'gap', 'test_key', 'count_mode', 'display', 'milestone_step', 'name_style', 'combo' }
local ui_wanted = {}
for _, k in ipairs(UI_KEYS) do ui_wanted['heavy_kill_notice.' .. k] = k end
local ui_state, ui_last_lang, ui_next_probe = nil, nil, -1e9

local function find_menu_state()
    local menu = rawget(_G, 'ModOptionsMenu')
    local dbg = rawget(_G, 'debug')
    if type(menu) ~= 'table' or type(dbg) ~= 'table' or type(dbg.getupvalue) ~= 'function' then return nil end
    for _, name in ipairs({ 'get', 'set', 'register_option' }) do
        local fn = menu[name]
        if type(fn) == 'function' then
            for index = 1, 24 do
                local un, uv = dbg.getupvalue(fn, index)
                if un == nil then break end
                if un == 'state' and type(uv) == 'table' and type(uv.pending) == 'table' and type(uv.values) == 'table' then
                    return uv
                end
            end
        end
    end
    return nil
end

local function ui_text(mode, key)
    local en, zh = UI.en[key], UI.zh[key]
    if not en then return nil end
    if mode == 2 then return zh end
    if mode == 3 then
        local out = { label = en.label .. ' / ' .. zh.label, desc = en.desc .. '  ' .. zh.desc }
        if en.choices then
            local c = {}
            for i = 1, #en.choices do c[i] = en.choices[i] .. ' / ' .. (zh.choices[i] or '') end
            out.choices = c
        end
        return out
    end
    return en
end

local function apply_menu_labels()
    if not ui_state then return end
    local mode = lang:get()
    local title = UI.en.title
    if mode == 2 then title = UI.zh.title elseif mode == 3 then title = UI.en.title .. ' / ' .. UI.zh.title end
    local seen = {}
    local function visit(t, depth)
        if type(t) ~= 'table' or seen[t] or depth > 6 then return end
        seen[t] = true
        local k = type(t.id) == 'string' and ui_wanted[t.id] or nil
        if k then
            local tx = ui_text(mode, k)
            if tx then t.label = tx.label; t.description = tx.desc; if tx.choices then t.choices = tx.choices end end
            if title then t.mod = title end
        end
        for key, value in pairs(t) do
            local bk = type(key) == 'string' and ui_wanted[key] or nil
            if bk and type(value) == 'table' then
                local tx = ui_text(mode, bk)
                if tx then value.label = tx.label; value.description = tx.desc; if tx.choices then value.choices = tx.choices end end
                if title then value.mod = title end
            elseif type(value) == 'table' then
                visit(value, depth + 1)
            end
        end
    end
    visit(ui_state, 0)
end

local function ui_tick()
    if not ui_state then
        if clock < ui_next_probe then return end
        ui_next_probe = clock + 1.0
        ui_state = find_menu_state()
        if not ui_state then return end
        ui_last_lang = nil
    end
    if ui_last_lang ~= lang:get() then
        ui_last_lang = lang:get()
        apply_menu_labels()
    end
end

-- === queue / rate limit ========================================================================
local queue = {}
local MAX_QUEUE = 16
local last_send = -1e9
local counts = {}      -- killer peer -> { types = {type hex -> n}, total = n } (this mission)
local function reset_counts() counts = {} end

local function localize(entry)
    if not entry then return nil end
    if lang:get() == 2 then return entry.zh or entry.en end   -- choice index 2 = 简体中文
    return entry.en or entry.zh
end

-- One line in one language. who is the roster name (same in both); victim/weapon have zh+en names.
-- compact = drop the verbs and join with separators: "A · Charger · EAT-17".
local function compose_lang(who, victim, weapon, code, compact)
    local function name(entry)
        if not entry then return nil end
        if code == 'zh' then return entry.zh or entry.en end
        return entry.en or entry.zh
    end
    local vname = name(victim) or (code == 'zh' and '重甲单位' or 'Heavy unit')
    local wname = name(weapon)
    if compact then
        if wname then return string.format('%s · %s · %s', who, vname, wname) end
        return string.format('%s · %s', who, vname)
    end
    if code == 'zh' then
        if wname then return string.format('%s 用 %s 击杀了 %s', who, wname, vname) end
        return string.format('%s 击杀了 %s', who, vname)
    else
        if wname then return string.format('%s killed %s with %s', who, vname, wname) end
        return string.format('%s killed %s', who, vname)
    end
end

local function compose(who, victim_hex, weapon_hex, per_count, total_count, compact)
    local victim = CATALOG[victim_hex]
    local weapon
    if showWeapon:get() ~= false then weapon = weapon_hex and weapon_name_for(weapon_hex) end
    local function suffix(code)
        local m = countMode:get()
        if m == 1 then return '' end
        local parts = {}
        if (m == 2 or m == 4) and per_count then
            parts[#parts + 1] = code == 'zh' and ('计数：' .. per_count) or ('count: ' .. per_count)
        end
        if (m == 3 or m == 4) and total_count then
            parts[#parts + 1] = code == 'zh' and ('本局重甲：' .. total_count) or ('heavy kills: ' .. total_count)
        end
        if #parts == 0 then return '' end
        return ' ' .. table.concat(parts, ' / ')
    end
    local mode = lang:get()
    if mode == 2 then return compose_lang(who, victim, weapon, 'zh', compact) .. suffix('zh') end
    if mode == 3 then                                            -- Bilingual
        if compact then                                          -- one short line: 中文名/English
            local function both(entry)
                if not entry then return nil end
                return (entry.zh or entry.en) .. '/' .. (entry.en or entry.zh)
            end
            local vname = both(victim) or '重甲/Heavy'
            local wname = weapon and both(weapon)
            local line = wname and string.format('%s · %s · %s', who, vname, wname) or string.format('%s · %s', who, vname)
            return line .. suffix('zh')
        end
        return compose_lang(who, victim, weapon, 'zh', false) .. suffix('zh') .. ' | ' ..
               compose_lang(who, victim, weapon, 'en', false) .. suffix('en')
    end
    return compose_lang(who, victim, weapon, 'en', compact) .. suffix('en')
end

-- Milestones mode: a bit of flavour instead of a serious per-kill report.
-- Calibrated so a dedicated anti-heavy run (20-40 heavies a match) reads as: 5 = warm-up,
-- 20-40 = solid, and past 40 every step earns a stronger line.
local MILESTONE_PRAISE = {
    zh = { '才刚热身', '手感来了', '渐入佳境', '这波很稳', '有点东西', '相当能打', '效率很高', '超标发挥', '效率拉满', '反重之神', '已经离谱了' },
    en = { 'just warming up', 'finding the groove', 'getting there', 'solid', 'on a roll', 'very capable', 'very efficient', 'above baseline', 'max efficiency', 'heavy slayer', 'this is absurd' },
}
local function praise_for(level, code)
    local list = MILESTONE_PRAISE[code]
    if level < 1 then level = 1 end
    if level > #list then level = #list end
    return list[level]
end
local function compose_milestone(who, total, step)
    local level = math.floor(total / step)
    local function line(code)
        if code == 'zh' then
            return string.format('%s 干掉了 %d 个重甲单位，%s', who, total, praise_for(level, 'zh'))
        end
        return string.format('%s has taken down %d heavies - %s', who, total, praise_for(level, 'en'))
    end
    local mode = lang:get()
    if mode == 2 then return line('zh') end
    if mode == 3 then return line('zh') .. ' | ' .. line('en') end
    return line('en')
end

-- Who to name: the full roster name, or the in-game player number P1-P4 (short, language-neutral).
local function who_for(peer, killer)
    if nameStyle:get() == 2 then
        local slot = killer and tonumber(killer.slot)
        if slot then return 'P' .. (slot + 1) end
    end
    local nm = refresh_names(clock)
    return nm[peer] or ('Player ' .. tostring(peer):sub(-4))
end

-- Combo flavour (Milestones mode): several heavies down in a row.
local COMBO_WINDOW, COMBO_N, COMBO_COOLDOWN = 3.0, 3, 6.0
local function compose_combo(who, n)
    local function line(code)
        if code == 'zh' then return string.format('%s 连宰 %d 只重甲！', who, n) end
        return string.format('%s took down %d heavies in a row!', who, n)
    end
    local mode = lang:get()
    if mode == 2 then return line('zh') end
    if mode == 3 then return line('zh') .. ' | ' .. line('en') end
    return line('en')
end

local function enqueue(text, mine)
    queue[#queue + 1] = { text = text, mine = mine == true }
    while #queue > MAX_QUEUE do table.remove(queue, 1) end
end

local function pump()
    if #queue == 0 then return end
    local mode = chatMode:get()
    if mode == 4 then queue = {}; diag('off', 'heavy kill notice: chat broadcast is Off'); return end
    if clock - last_send < (minGap:get() or 10) / 10 then return end
    local host = is_host()
    local item = queue[1]
    if mode == 2 and not host then table.remove(queue, 1); diag('hostonly', 'heavy kill notice: skipped (client, Host only)'); return end
    if mode == 1 and not host and not item.mine then
        table.remove(queue, 1); diag('ownonly', 'heavy kill notice: skipped (client, not my kill)'); return
    end
    table.remove(queue, 1)
    local ok, why = raw_send(item.text)
    if ok then
        last_send = clock
        mod:log('heavy kill notice broadcast: ' .. item.text)
    else
        mod:log('heavy kill notice send failed: ' .. tostring(why))
    end
end

-- === HD2Runtime events =========================================================================
local HKN_RES = 'mods/heavykill/heavy_kill_notice'
local function subscribe(name, fn, id)
    local ok, sub = pcall(function()
        return hd2.events.on(name, fn, { id = id, priority = 100, scope = 'session', owner = HKN_RES, max_failures = 0 })
    end)
    return ok and type(sub) == 'table' and sub.state ~= 'rejected'
end

local seen_kills = 0
local function norm_hex(v)
    if type(v) == 'number' then return string.format('%016X', v % 2 ^ 64) end
    if type(v) ~= 'string' then return nil end
    local hx = v:gsub('^0[xX]', ''):upper()
    if #hx < 16 then hx = string.rep('0', 16 - #hx) .. hx end
    if #hx ~= 16 or hx:match('^%x+$') == nil then return nil end
    return hx
end

local function on_killed(e)
    if type(e) ~= 'table' then return end
    seen_kills = seen_kills + 1
    local hx = norm_hex(e.type)
    local peer = e.killer_peer
    if type(peer) == 'number' then peer = string.format('%016X', peer) end
    if type(peer) == 'string' then peer = peer:upper() end
    local heavy = hx ~= nil and HEAVY[hx] == true
    if seen_kills <= 40 or seen_kills % 25 == 0 then
        mod:log(string.format('killed #%d: type=%s hx=%s heavy=%s peer=%s local_killer=%s enabled=%s',
            seen_kills, tostring(e.type), tostring(hx), tostring(heavy), tostring(peer),
            tostring(e.local_killer), tostring(enabled:get())))
    end
    if enabled:get() ~= true then return end
    if not heavy or type(peer) ~= 'string' or #peer < 16 then return end
    local ws = weaponSource:get()
    local weapon_hex, source
    if ws ~= 3 then                                              -- precise: the killing blow's dealer
        weapon_hex = weapon_from_damage(e.entity_id)
        if weapon_hex then source = 'damage' end
    end
    if not weapon_hex and ws ~= 1 then                           -- fallback: the killer's held weapon
        local killer = e.killer
        if killer and type(killer.avatar) == 'function' then
            local ok, av = pcall(function() return killer:avatar() end)
            if ok and av and av.id then
                local held = held_weapon(av.id)
                if held then weapon_hex = entity_type(held); source = 'held' end
            end
        end
    end
    local c = counts[peer]
    if not c then c = { types = {}, total = 0, times = {} }; counts[peer] = c end
    c.types[hx] = (c.types[hx] or 0) + 1
    c.total = c.total + 1
    local who = who_for(peer, e.killer)
    local style = display:get()
    if style == 3 then                                            -- Milestones: only every N kills
        local step = math.floor(tonumber(milestoneStep:get()) or 5)
        if step < 1 then step = 1 end
        if c.total % step == 0 then
            enqueue(compose_milestone(who, c.total, step), e.local_killer == true)
            diag('queued', 'heavy kill notice: milestone queued (total=' .. c.total .. ')')
        end
        if combo:get() == true then                               -- combo flavour: several in a row
            local times = c.times or {}
            c.times = times
            times[#times + 1] = clock
            local cutoff, keep = clock - COMBO_WINDOW, 0
            for i = 1, #times do
                if times[i] >= cutoff then keep = keep + 1; times[keep] = times[i] end
            end
            for i = #times, keep + 1, -1 do times[i] = nil end
            if keep >= COMBO_N and (clock - (c.last_combo or -1e9)) >= COMBO_COOLDOWN then
                c.last_combo = clock
                c.times = {}
                enqueue(compose_combo(who, keep), e.local_killer == true)
                diag('queued', 'heavy kill notice: combo queued (n=' .. keep .. ')')
            end
        end
        return
    end
    enqueue(compose(who, hx, weapon_hex, c.types[hx], c.total, style == 2), e.local_killer == true)
    diag('queued', 'heavy kill notice: queued (q=' .. #queue .. ', weapon_src=' .. tostring(source) ..
        ', weapon=' .. tostring(weapon_hex) .. ', killer_count=' .. c.types[hx] .. '/' .. c.total .. ')')
end

local eventsReady = subscribe('entity_killed', on_killed, 'hkn-killed')
subscribe('mission_started', function() reset_counts() end, 'hkn-mission-start')
subscribe('mission_ended', function() names = {}; names_at = -1e9; reset_counts() end, 'hkn-mission-end')

-- === timers ====================================================================================
local f9 = false
mod:every(0.05, function()
    clock = clock + 0.05
    pcall(ui_tick)
    pcall(scan_queue)
    pcall(pump)
    local k = testKey:get() == true and mem.key and mem.key(0x78) or nil   -- optional F9 self-test
    local down = k ~= nil and (k % 65536) >= 32768
    if down and not f9 then
        local m = 'Heavy Kill Notice: test (' .. (is_host() and 'host' or 'client') .. ')'
        local ok, why = raw_send(m)
        mod:log('heavy kill notice test send: ' .. tostring(ok) .. (ok and '' or (' ' .. tostring(why))))
    end
    f9 = down
end)

-- ===============================================================================================
local ready_names = 0
for _ in pairs(refresh_names(clock)) do ready_names = ready_names + 1 end
local function chat_on()
    local ctx = read_ptr(game + OFF_CTX)
    if not ctx then return false end
    local e = read_u32(ctx + OFF_CHAT)
    return e ~= nil and e % 256 ~= 0
end
local state = {
    version = '1.7.0',
    ready = true,
    has_events = eventsReady,
}
rawset(_G, key, state)
mod:log(string.format('heavy kill notice ready v1.7.0 (events=%s host=%s chat=%s names=%d)',
    tostring(eventsReady), tostring(is_host()), tostring(chat_on()), ready_names))
if rawget(_G, 'HeavyKillNoticeTest') then
    state._test = { queue = queue, pump = pump, is_host = is_host, compose = compose,
        refresh = refresh_names, raw_send = raw_send, clock = function() return clock end,
        held = held_weapon, etype = entity_type, wname = weapon_name_for, wok = function() return S.weapon_ok end,
        scan_queue = scan_queue, weapon_from_damage = weapon_from_damage, network = network,
        find_menu_state = find_menu_state, apply_menu_labels = apply_menu_labels }
end
return state
