-- Build-only unit/ability declarations. Original implementation; converter code is not embedded.
local M = {}
local supported = {
    unit = {unam=true, uhpm=true, umpi=true, umvs=true, usca=true, uabi=true},
    ability = {anam=true, alev=true, aher=true, aite=true, acdn=true, amcs=true,
        aran=true, aare=true, adur=true, ahdu=true, atp1=true, aub1=true},
}
local function read(path, optional)
    local f, err = io.open(path, 'rb')
    if not f then if optional then return nil end; error(err, 0) end
    local s = f:read('a'); f:close(); return s
end
local function keys(t)
    local r = {}; for k in pairs(t) do r[#r+1] = k end
    table.sort(r); return r
end
local function id(s)
    assert(type(s)=='string' and #s==4 and s:match('^[A-Za-z0-9_]+$'),
        'id/parent must be exactly four ASCII letters, digits or underscores')
    return s
end
local function metadata(root)
    local out, kind, row = {}, nil, nil
    for line in read(root .. '/prebuilt/metadata.ini'):gmatch('[^\r\n]+') do
        local section = line:match('^%[([^%]]+)%]$')
        if section then
            if section:sub(1,1)=='.' then row={}; if kind then out[kind][#out[kind]+1]=row end
            else kind=section; out[kind]={}; row=nil end
        elseif row then
            local k,v = line:match('^(%w+) = (.+)$'); if k then row[k]=tonumber(v) or v end
        end
    end
    local result={}
    for _,k in ipairs({'unit','ability'}) do
        result[k]={}
        for _,r in ipairs(assert(out[k], 'missing metadata kind')) do
            if supported[k][r.id] then result[k][r.id]=r end
        end
        for field in pairs(supported[k]) do
            assert(result[k][field], 'metadata missing supported field '..field)
        end
    end
    return result
end
local function standard_ids(root, kind)
    local out={}
    for s in read(root..'/prebuilt/Custom/'..kind..'.ini'):gmatch('%[([^%]\r\n]+)%]') do out[s]=true end
    return out
end
-- Find boundaries/collisions while retaining the exact existing record bytes.
local function existing(data, extended)
    if not data then return {version=2, original='', custom='', count=0, ids={}} end
    local p=1
    local function int() local n; n,p=string.unpack('<i4',data,p); return n end
    local function raw()
        local s=data:sub(p,p+3); assert(#s==4,'truncated object id'); p=p+4; return s
    end
    local version=int()
    assert(version==1 or version==2, 'unsupported existing object version (only 1/2 supported)')
    local ids, parts, counts = {}, {}, {}
    for section=1,2 do
        local count=int(); assert(count>=0 and count<=100000, 'invalid object count')
        counts[section]=count
        local start=p
        for _=1,count do
            local old,new=raw(),raw(); ids[old]=true; if new~='\0\0\0\0' then ids[new]=true end
            local mods=int(); assert(mods>=0 and mods<=1000000,'invalid modification count')
            for _=1,mods do
                raw(); local t=int(); assert(t>=0 and t<=3,'invalid field type')
                if extended then int(); int() end
                if t==3 then local at=assert(data:find('\0',p,true),'unterminated string'); p=at+1
                else raw() end
                raw()
            end
        end
        parts[section]=data:sub(start,p-1)
    end
    assert(p==#data+1,'unexpected trailing object bytes')
    return {version=version, original=string.pack('<i4',counts[1])..parts[1],
        custom=parts[2], count=counts[2], ids=ids}
end
function M.compile(declarations, work, dataRoot)
    local meta=metadata(dataRoot)
    local objects={unit={},ability={}}
    local seen={}
    local env={}
    for _,kind in ipairs({'unit','ability'}) do
        env[kind]=function(o)
            assert(type(o)=='table','declaration must be a table')
            for k in pairs(o) do
                assert(k=='id' or k=='parent' or k=='fields','unknown declaration key '..tostring(k))
            end
            id(o.id); id(o.parent)
            assert(not seen[o.id], 'duplicate object id '..o.id); seen[o.id]=true
            assert(type(o.fields)=='table','fields must be a table')
            -- Capture at declaration time. Reusing a table cannot mutate an
            -- earlier ID or its level data and bypass duplicate validation.
            local snapshot={id=o.id,parent=o.parent,fields={}}
            for field,value in pairs(o.fields) do
                assert(type(field)=='string','field IDs must be strings')
                if type(value)=='table' then
                    local levels={}; for level,v in pairs(value) do levels[level]=v end
                    snapshot.fields[field]=levels
                else snapshot.fields[field]=value end
            end
            objects[kind][#objects[kind]+1]=snapshot
        end
    end
    assert(loadfile(declarations,'t',env))()
    local outputs={}
    for _,kind in ipairs({'unit','ability'}) do
        local ext=kind=='unit' and 'w3u' or 'w3a'
        local path=work..'/war3map.'..ext
        if #objects[kind]>0 then
            assert(not read(path..'.ini',true) and not read(work..'/table/'..kind..'.ini',true),
                'uncompiled LNI object input: '..kind)
            local base=existing(read(path,true),kind=='ability')
            local defaults=standard_ids(dataRoot,kind)
            table.sort(objects[kind],function(a,b) return a.id<b.id end)
            local records={}
            for _,o in ipairs(objects[kind]) do
                assert(defaults[o.parent], 'unknown standard parent '..o.parent)
                assert(not defaults[o.id] and not base.ids[o.id], 'object id collision '..o.id)
                local mods={}
                local levels=o.fields.alev
                if kind=='ability' then
                    assert(type(levels)=='number' and levels%1==0 and levels>=1 and levels<=100,
                        'ability requires alev integer in 1..100')
                end
                for _,field in ipairs(keys(o.fields)) do
                    local r=assert(meta[kind][field], 'unsupported '..kind..' field '..tostring(field))
                    local value=o.fields[field]
                    local repeated=(r['repeat'] or 0)>0
                    local function emit(v,level)
                        local t=r.type
                        if t==3 then
                            assert(type(v)=='string' and not v:find('\0',1,true),
                                field..' expects string without NUL')
                        else
                            assert(type(v)=='number' and v==v and math.abs(v)<math.huge,
                                field..' expects finite number')
                            if t==0 then
                                assert(v%1==0 and v>=-2147483648 and v<=2147483647,field..' expects int32')
                            else assert(math.abs(v)<=3.402823466e38,field..' exceeds float32') end
                        end
                        local payload=t==3 and (v..'\0') or string.pack(t==0 and '<i4' or '<f',v)
                        mods[#mods+1]=field..string.pack('<i4',t)..
                            (kind=='ability' and string.pack('<i4i4',level,0) or '')..payload..'\0\0\0\0'
                    end
                    if repeated then
                        assert(type(value)=='table',field..' requires dense level table')
                        local count=0
                        for k in pairs(value) do
                            assert(type(k)=='number' and k%1==0 and k>=1 and k<=levels,field..' invalid level index')
                            count=count+1
                        end
                        assert(count==levels,field..' requires exactly alev values')
                        for level=1,levels do emit(value[level],level) end
                    else assert(type(value)~='table',field..' is scalar'); emit(value,0) end
                end
                records[#records+1]=o.parent..o.id..string.pack('<i4',#mods)..table.concat(mods)
            end
            if base.original=='' then base.original=string.pack('<i4',0) end
            outputs[path]=string.pack('<i4',base.version)..base.original..
                string.pack('<i4',base.count+#records)..base.custom..table.concat(records)
        end
    end
    -- Validate every declaration before touching either output. Writes are
    -- limited to pack's scratch directory; disk errors are not transactional.
    for _,path in ipairs(keys(outputs)) do
        local f=assert(io.open(path,'wb')); assert(f:write(outputs[path])); assert(f:close())
    end
    return outputs
end
M.existing=existing
return M
