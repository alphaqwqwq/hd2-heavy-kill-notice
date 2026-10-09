-- Smoke test for Heavy Kill Notice.
-- Loads build/heavy_kill_notice.built.lua with a fake HD2Runtime, a fake ffi and a fake
-- game.dll memory image, then drives the entity_killed callback and the tick, and checks
-- what the native chat sender would receive.

local SRC = MOD_SRC
local BASE = 0x140000000
local SEND_RVA = 0x1097560
local SEND_SIG = "\65\86\65\87\72\129\236\120\4\0\0\72\139\5\158\74\90\1\72\51\196\72\137\132\36\80\4\0\0\128\57\0"
local OFF_CTX, OFF_ROSTER, OFF_CHAT = 0x347CEF0, 0x347CED8, 0xC418
local OFF_LOCAL, OFF_HOST = 0xB398, 0xB3A8
local ROSTER, CTX = 0x200000000, 0x300000000

-- ---------------- fake sparse memory ----------------
local chunks = {}
local function put(addr, s) chunks[#chunks + 1] = { a = addr, s = s } end
local function u32s(v)
    v = v % 4294967296
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216))
end
local function u64s(v) return u32s(v % 4294967296) .. u32s(math.floor(v / 4294967296)) end
local function mem_get(addr, size)
    for ci = #chunks, 1, -1 do
        local c = chunks[ci]
        if addr >= c.a and addr < c.a + #c.s then
            local off = addr - c.a
            local avail = #c.s - off
            local head = c.s:sub(off + 1, off + math.min(avail, size))
            if avail >= size then return head end
            return head .. string.rep('\0', size - avail)
        end
    end
    return nil
end

-- PE header
local pe = string.rep('\0', 4096)
local function splice(s, off, repl) return s:sub(1, off) .. repl .. s:sub(off + #repl + 1) end
pe = splice(pe, 0, 'MZ')
pe = splice(pe, 60, u32s(0x80))
pe = splice(pe, 0x80, 'PE\0\0')
pe = splice(pe, 0x88, u32s(0x6AB3B43F))   -- stamp
pe = splice(pe, 0xD0, u32s(0x4744000))    -- image size
put(BASE, pe)
put(BASE + SEND_RVA, SEND_SIG)
put(BASE + OFF_ROSTER, u64s(ROSTER))      -- *(game+roster) -> persona table
put(BASE + OFF_CTX, u64s(CTX))            -- *(game+ctx)   -> session context

-- roster: one persona with peer + name
local function persona(peer_lo, peer_hi, name)
    local rec = u32s(peer_lo) .. u32s(peer_hi) .. name .. '\0' .. string.rep('\0', 8)
    return rec .. string.rep('\0', 0xC0 - #rec)
end
put(ROSTER + 0, persona(0x11111111, 0x00000001, 'Alpha'))
put(ROSTER + 0xC0, persona(0x22222222, 0x00000002, 'Bravo'))

-- session context
local local_peer = u32s(0x11111111) .. u32s(0x00000001)
put(CTX + OFF_LOCAL, local_peer)
put(CTX + OFF_HOST, local_peer)           -- host now
put(CTX + OFF_CHAT, u32s(1))              -- text chat enabled

-- wielder hash map + entity map, so the killer's held weapon resolves.
-- wielder profile: wielder=53634080 wielderHash=48 slots=96 stride=464
-- entity map     : entities=54968216 entityMap=15838896 descriptors=15937304 stride=24
-- damage queue   : global=55037752 base=4384 stride=112 count=2101536
-- avatar map     : mapSlots=15871688 entityBase=15937312 entityStride=24
local AVATAR, WEAPON_ENTITY = 0x00012345, 0x00067890
local DEALER_ENTITY, DEALER_GOID, VICTIM = 0x00099999, 0x0000ABCD, 0x00077777
local WHEX_LO, WHEX_HI = 0x1FA49630, 0x02EECD0B       -- GL-21 Grenade Launcher (held)
local SHEX_LO, SHEX_HI = 0x42B62BEC, 0x0DC7A183       -- EAT-17 Expendable Anti-Tank (dealer)
local WM, HS, REC = 0x400000000, 0x400010000, 0x400020000
local EM, ES, DESC = 0x500000000, 0x500100000, 0x500200000
put(BASE + 53634080, u64s(WM))
put(WM + 48, u64s(HS) .. u32s(2) .. u32s(0xFFFFFFFF) .. u32s(0))
put(HS, u32s(AVATAR) .. u32s(0) .. u32s(0xFFFFFFFF) .. u32s(0))
put(WM + 96, u64s(REC))
put(REC, u32s(WEAPON_ENTITY) .. string.rep('\0', 4))
put(BASE + 54968216, u64s(EM))
put(EM + 15838896, u64s(ES) .. u32s(2) .. u32s(0xFFFFFFFF) .. u32s(0))
put(ES, u32s(WEAPON_ENTITY) .. u32s(0) .. u32s(DEALER_ENTITY) .. u32s(1))
put(EM + 15937304, u32s(WHEX_LO) .. u32s(WHEX_HI) .. u32s(WEAPON_ENTITY) .. string.rep('\0', 12))
put(EM + 15937304 + 24, u32s(SHEX_LO) .. u32s(SHEX_HI) .. u32s(DEALER_ENTITY) .. string.rep('\0', 12))
-- damage queue: one event, target=VICTIM, dealer_goid=DEALER_GOID
local QSYS, NSLOTS = 0x600000000, 0x600100000
put(BASE + 55037752, u64s(QSYS))
put(QSYS + 2101536, u32s(1))                                     -- count
put(QSYS + 4384, u32s(VICTIM) .. u32s(0) .. u32s(0) .. u32s(0) .. u32s(DEALER_GOID) .. string.rep('\0', 92))
-- avatar network map: DEALER_GOID -> record index 1 (whose +8 entity is DEALER_ENTITY)
put(EM + 15871688, u64s(NSLOTS) .. u32s(2) .. u32s(0xFFFFFFFF) .. u32s(0))
put(NSLOTS, u32s(DEALER_GOID) .. u32s(1) .. u32s(0xFFFFFFFF) .. u32s(0))

-- ---------------- fake ffi ----------------
local sends = {}
local OBJ, nextid = {}, 0x10000
local function newarr(n) return setmetatable({ n = n }, { __index = function(t, k) return rawget(t, k) end }) end
local ffi = {}
function ffi.cdef() end
local kernel
function ffi.load() return kernel end
function ffi.new(ct, n)
    if type(ct) == 'string' and ct:find('%[%?%]') then
        local b = { n = n, s = '' }
        return setmetatable(b, { __index = function(t, k) if k == 's' then return rawget(t, 's') end end })
    end
    return { [0] = 0 }
end
function ffi.cast(ct, v)
    if type(ct) == 'string' and ct:find('%)%(uint64_t') then
        return function(chat, unused, id)
            local b = OBJ[id]
            sends[#sends + 1] = { chat = chat, text = (b and b.s) or '' }
        end
    end
    if ct == 'uintptr_t' and type(v) == 'table' then
        if not v.__id then nextid = nextid + 1; v.__id = nextid; OBJ[nextid] = v end
        return v.__id
    end
    if type(ct) == 'string' and ct:find('uint32_t') and type(v) == 'table' then
        return setmetatable({}, { __index = function(_, i)
            local o = i * 4; local s = v.s or ''
            if o + 4 > #s then return 0 end
            local a, b, c, d = s:byte(o + 1, o + 4)
            return a + b * 256 + c * 65536 + d * 16777216
        end })
    end
    return v
end
function ffi.copy(dest, src, n) dest.s = src:sub(1, n) end
function ffi.string(buf, n) return buf.s or '' end
kernel = {
    HKN_GetCurrentProcess = function() return 1 end,
    HKN_GetModuleHandleA = function(name) if name == 'game.dll' then return BASE end return nil end,
    HKN_GetAsyncKeyState = function() return 0 end,
    HKN_ReadProcessMemory = function(proc, addr, out, size, cnt)
        local s = mem_get(ffi.cast('uintptr_t', addr), size)
        if not s then return 0 end
        if out then out.s = s end
        if cnt then cnt[0] = size end
        return 1
    end,
}

-- ---------------- fake hd2 ----------------
local logged = {}
local killed_cb, mission_cb
local every_cbs = {}
local values = {}
local function handle(id) return { get = function() return values[id] end } end
local hd2 = {
    mod = function() return {
        log = function(_, m) logged[#logged + 1] = tostring(m) end,
        every = function(_, dt, fn) every_cbs[#every_cbs + 1] = fn end,
    } end,
    options = function()
        return {
            toggle = function(_, def) values[def.id] = def.default; return handle(def.id) end,
            slider = function(_, def) values[def.id] = def.default; return handle(def.id) end,
            choice = function(_, def) values[def.id] = def.default; return handle(def.id) end,
        }
    end,
    events = {
        on = function(name, fn)
            if name == 'entity_killed' then killed_cb = fn elseif name == 'mission_ended' then mission_cb = fn end
            return { state = 'active' }
        end,
    },
}

-- ---------------- load ----------------
local function loadmod()
    package.loaded['ffi'] = ffi
    package.preload['mods/skyeshade/hd2runtime'] = function() return hd2 end
    _G.CowboyBingusModLoader = { api = 1 }
    _G.HeavyKillNoticeFfi = nil
    _G.HeavyKillNoticeMod = nil
    _G.HeavyKillNoticeTest = true
    local f = assert(loadstring(SRC, 'hkn'))
    return f()
end

local out, fails = {}, 0
local function check(name, got, want)
    local ok = (got == want)
    if not ok then fails = fails + 1 end
    out[#out + 1] = string.format('[%s] %-52s got %s, want %s', ok and 'PASS' or 'FAIL', name, tostring(got), tostring(want))
end

-- 1) wrong build disables
local function stamp_pe(v)
    local p = splice(pe, 0x88, u32s(v)); put(BASE, p)
end
stamp_pe(0xDEADBEEF)
local bad = loadmod()
check('wrong build -> disabled', bad, false)
-- fix build
stamp_pe(0x6AB3B43F)

-- 2) correct build loads
local M = loadmod()
check('correct build -> table', type(M), 'table')
check('events subscribed', M.has_events, true)

-- new defaults: simplest bilingual out of the box
check('default language = bilingual', values.language, 3)
check('default display = compact', values.display, 2)
check('default name style = P#', values.name_style, 2)
values.language = 2; values.display = 1; values.name_style = 1; values.combo = false

local function tick(n) for _ = 1, n do for _, fn in ipairs(every_cbs) do fn() end end end

-- 3) heavy kill -> broadcast with roster name
sends = {}
killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000111111111', killer = nil })
tick(40) -- ~2 s
check('heavy kill sent', #sends, 1)
check('uses roster name', sends[1] and sends[1].text:find('Alpha', 1, true) ~= nil, true)
check('names the Charger', sends[1] and (sends[1].text:find('Charger', 1, true) ~= nil or sends[1].text:find('冲锋虫', 1, true) ~= nil), true)
check('no weapon word when unknown', sends[1] and sends[1].text:find('with', 1, true) == nil, true)

-- 4) non-heavy kill -> nothing
sends = {}
killed_cb({ type = '3D0E03E2D574E1CA', killer_peer = '0000000111111111' })  -- Hunter (light)
tick(40)
check('light kill not sent', #sends, 0)

-- 5) rate limit: two heavies back to back -> one send
sends = {}
killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000111111111' })
killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000111111111' })
tick(5)
check('rate limited to one per gap', #sends, 1)

-- 6) chat mode off -> nothing (flush the queue first)
tick(40)
sends = {}
values.chat_mode = 4
killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000111111111' })
tick(40)
check('chat off -> nothing', #sends, 0)
values.chat_mode = 1

-- 7) host-only + client -> nothing
put(CTX + OFF_HOST, u32s(0x99999999) .. u32s(0x00000009))
values.chat_mode = 2
sends = {}
killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000111111111' })
tick(40)
check('client + host-only -> nothing', #sends, 0)

-- 7b) smart mode + client: own kills go out, others do not
values.chat_mode = 1
sends = {}
killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000222222222', local_killer = false })
tick(40)
check('client smart: others not sent', #sends, 0)
killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000111111111', local_killer = true })
tick(40)
check('client smart: own kill sent', #sends, 1)
values.chat_mode = 1
put(CTX + OFF_HOST, local_peer)

-- 8) english output
tick(40)
sends = {}
values.language = 1
killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000222222222' })  -- Bravo
tick(40)
check('english uses killer name', sends[1] and sends[1].text:find('Bravo', 1, true) ~= nil, true)
check('english sentence', sends[1] and sends[1].text:find('killed', 1, true) ~= nil, true)

-- 9) weapon path: the killer's held weapon resolves to a name (explicit "precise, else held")
tick(40)
sends = {}
values.language = 2
values.weapon_source = 2
local killer = { avatar = function() return { id = AVATAR } end }
killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000111111111', killer = killer })
tick(40)
check('weapon kill sent', #sends, 1)
check('weapon named in chat', sends[1] and (sends[1].text:find('GL-21', 1, true) ~= nil), true)
values.weapon_source = 1

-- 10) damage-queue dealer wins over the held weapon (a stratagem kill)
tick(40)                                     -- let scan_queue record recent[VICTIM]
sends = {}
values.language = 1
killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000111111111',
            entity_id = VICTIM, killer = killer })
tick(40)
check('dealer kill sent', #sends, 1)
check('dealer weapon (EAT-17) beats held (GL-21)', sends[1] and (sends[1].text:find('EAT-17', 1, true) ~= nil), true)

-- 11) bilingual: both languages on one line
tick(40)
sends = {}
values.language = 3
killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000111111111',
            entity_id = VICTIM, killer = killer })
tick(40)
check('bilingual sent', #sends, 1)
check('bilingual has EN', sends[1] and (sends[1].text:find('killed', 1, true) ~= nil), true)
check('bilingual has ZH', sends[1] and (sends[1].text:find('击杀了', 1, true) ~= nil), true)

-- 12) precise-only + no captured source -> the weapon is hidden
tick(40)
sends = {}
values.language = 2
values.weapon_source = 1
killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000111111111', killer = killer })
tick(40)
check('unknown weapon still broadcast', #sends, 1)
check('unknown weapon hidden (no 用)', sends[1] and (sends[1].text:find('用', 1, true) == nil), true)
check('unknown weapon: still names victim', sends[1] and (sends[1].text:find('冲锋虫', 1, true) ~= nil), true)

-- 13) per-mission heavy kill count: per type / total / both, and reset
tick(40)
sends = {}
values.count_mode = 2          -- Per type
values.language = 2
killed_cb({ type = 'DCF8E74212FBEE3B', killer_peer = '0000000111111111' })   -- Impaler
tick(40)
check('count per type starts at 1', sends[1] and (sends[1].text:find('计数：1', 1, true) ~= nil), true)
killed_cb({ type = 'DCF8E74212FBEE3B', killer_peer = '0000000111111111' })
tick(40)
check('count per type increments', sends[2] and (sends[2].text:find('计数：2', 1, true) ~= nil), true)
mission_cb()                                                                  -- mission ended -> reset
killed_cb({ type = 'DCF8E74212FBEE3B', killer_peer = '0000000111111111' })
tick(40)
check('count resets each mission', sends[3] and (sends[3].text:find('计数：1', 1, true) ~= nil), true)

values.count_mode = 3          -- Per-mission total
killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000111111111' })   -- Charger
tick(40)
check('total count', sends[4] and (sends[4].text:find('本局重甲：2', 1, true) ~= nil), true)

values.count_mode = 4          -- Both
killed_cb({ type = 'DCF8E74212FBEE3B', killer_peer = '0000000111111111' })   -- Impaler again
tick(40)
check('both: per type', sends[5] and (sends[5].text:find('计数：2', 1, true) ~= nil), true)
check('both: total', sends[5] and (sends[5].text:find('本局重甲：3', 1, true) ~= nil), true)
killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000222222222' })   -- Bravo: independent count
tick(40)
check('counts are per killer (Bravo=1)', sends[6] and (sends[6].text:find('计数：1', 1, true) ~= nil), true)
check('per-killer total (Bravo=1)', sends[6] and (sends[6].text:find('本局重甲：1', 1, true) ~= nil), true)
values.count_mode = 1

-- 14) menu language hot-switch (BFV Kill Feedback's method: mutate the menu's spec tables in place)
local spec = { label = 'x', description = 'y' }
local fake_state = { pending = {}, values = {}, options = { ['heavy_kill_notice.enabled'] = spec } }
local function build_menu(state)
    return {
        get = function() return state.values end,
        set = function() end,
        register_option = function(id, s) if state.pending then end return true end,
        on_change = function() end,
    }
end
_G.ModOptionsMenu = build_menu(fake_state)
check('menu state probe finds the private table', M._test.find_menu_state() == fake_state, true)
values.language = 2
tick(40)
check('menu label -> 中文', spec.label, '启用')
values.language = 1
tick(40)
check('menu label -> English', spec.label, 'Enabled')
values.language = 3
tick(40)
check('menu label -> bilingual', spec.label, 'Enabled / 启用')
values.language = 2
_G.ModOptionsMenu = nil

-- 15) compact display: no verbs, separator style
tick(40)
sends = {}
values.display = 2
values.language = 2
values.count_mode = 1
killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000111111111', entity_id = VICTIM, killer = killer })
tick(40)
check('compact sent', #sends, 1)
check('compact: no verb', sends[1] and (sends[1].text:find('击杀了', 1, true) == nil), true)
check('compact: separator', sends[1] and (sends[1].text:find(' · ', 1, true) ~= nil), true)
check('compact: has weapon', sends[1] and (sends[1].text:find('EAT-17', 1, true) ~= nil), true)
values.display = 1

-- 16) milestones: only every N kills, with flavour
mission_cb()                                  -- reset counts
values.display = 3
values.milestone_step = 5
values.language = 2
values.combo = false
sends = {}
for _ = 1, 5 do killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000111111111' }) end
tick(40)
check('milestone: one line for 5 kills', #sends, 1)
check('milestone: counts 5', sends[1] and (sends[1].text:find('干掉了 5 个重甲单位', 1, true) ~= nil), true)
check('milestone: praise 1', sends[1] and (sends[1].text:find('才刚热身', 1, true) ~= nil), true)
for _ = 6, 10 do killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000111111111' }) end
tick(40)
check('milestone: counts 10', sends[2] and (sends[2].text:find('干掉了 10 个重甲单位', 1, true) ~= nil), true)
check('milestone: praise 2', sends[2] and (sends[2].text:find('手感来了', 1, true) ~= nil), true)
for _ = 11, 40, 5 do
    for _ = 1, 5 do killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000111111111' }) end
    tick(40)
end
check('milestone: 40', sends[8] and (sends[8].text:find('干掉了 40 个重甲单位', 1, true) ~= nil), true)
check('milestone: praise 40', sends[8] and (sends[8].text:find('超标发挥', 1, true) ~= nil), true)
values.display = 1

-- 17) P1-P4 player name (in-game number)
tick(40)
sends = {}
values.language = 1
values.display = 1
values.name_style = 2
local killer_slot = { avatar = function() return { id = AVATAR } end, slot = 1 }
killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000111111111', killer = killer_slot })
tick(40)
check('P# name used', sends[1] and (sends[1].text:find('P2', 1, true) ~= nil), true)
values.name_style = 1

-- 18) combo line (Milestones + combo: several in a row)
mission_cb()
values.display = 3
values.milestone_step = 100
values.combo = true
values.language = 1
sends = {}
for _ = 1, 3 do killed_cb({ type = '1A7FCDFF98C664B0', killer_peer = '0000000111111111' }) end
tick(40)
check('combo sent', #sends, 1)
check('combo text', sends[1] and (sends[1].text:find('in a row', 1, true) ~= nil), true)
values.display = 1
values.combo = false
values.milestone_step = 5

out[#out + 1] = fails == 0 and 'RESULT: ALL PASS' or ('RESULT: ' .. fails .. ' FAILURES')
return table.concat(out, '\n')
