local root, scratch = assert(arg[1]), assert(arg[2])
local compiler = assert(loadfile(root..'/tools/object-data/compiler.lua'))()
local data = root..'/tools/w3x2lni/data/enUS-1.27.1'
local function read(p) local f=assert(io.open(p,'rb')); local s=f:read('a'); f:close(); return s end
local function write(p,s) local f=assert(io.open(p,'wb')); f:write(s); f:close() end
local decl = scratch..'/objects.lua'
local u, a = scratch..'/war3map.w3u', scratch..'/war3map.w3a'
local pass=0
local function check(name,fn) fn(); pass=pass+1; print('[PASS] '..name) end
local function clear() os.remove(u); os.remove(a); os.remove(u..'.ini') end
local function compile(s) write(decl,s); return compiler.compile(decl,scratch,data) end
local function rejected(s, message)
    local beforeU, beforeA=read(u),read(a)
    local ok,err=pcall(compile,s)
    assert(not ok and tostring(err):find(message,1,true),tostring(err))
    assert(read(u)==beforeU and read(a)==beforeA,'rejection changed files')
end
clear()
compiler.compile(root..'/examples/11-object-data/objects.lua',scratch,data)
local firstU,firstA=read(u),read(a)
check('deterministic output and sorted fields',function()
    clear(); compiler.compile(root..'/examples/11-object-data/objects.lua',scratch,data)
    assert(read(u)==firstU and read(a)==firstA)
    clear(); compile("unit{id='uO11',parent='hfoo',fields={usca=1.15,umvs=300,uhpm=725,unam='Code Footman'}}")
    assert(read(u)==firstU)
    write(a,firstA)
end)
check('valid version 2 unit wire format',function()
    local s=read(u)
    local version,original,custom,p=string.unpack('<i4i4i4',s)
    assert(version==2 and original==0 and custom==1)
    assert(s:sub(p,p+7)=='hfoouO11')
    local count; count,p=string.unpack('<i4',s,p+8); assert(count==4)
    local values={}
    for _=1,count do
        local field=s:sub(p,p+3); p=p+4
        local t; t,p=string.unpack('<i4',s,p)
        local v
        if t==3 then local stop=assert(s:find('\0',p,true)); v=s:sub(p,stop-1); p=stop+1
        else v,p=string.unpack(t==0 and '<i4' or '<f',s,p) end
        assert(s:sub(p,p+3)=='\0\0\0\0'); p=p+4; values[field]=v
    end
    assert(p==#s+1 and values.uhpm==725 and values.unam=='Code Footman')
end)
check('invalid id',function() rejected("unit{id='bad',parent='hfoo',fields={}}",'four ASCII') end)
check('unknown parent',function() rejected("unit{id='uNEW',parent='zzzz',fields={}}",'unknown standard parent') end)
check('integer type',function() rejected("unit{id='uNEW',parent='hfoo',fields={uhpm=1.5}}",'expects int32') end)
check('string type',function() rejected("unit{id='uNEW',parent='hfoo',fields={unam=7}}",'expects string') end)
check('unsupported field',function() rejected("unit{id='uNEW',parent='hfoo',fields={fake=1}}",'unsupported unit field') end)
check('level table length',function() rejected("ability{id='ANEW',parent='AHbz',fields={alev=3,acdn={1,2}}}",'exactly alev') end)
check('level table indices',function() rejected("ability{id='ANEW',parent='AHbz',fields={alev=2,acdn={[1]=1,[3]=2}}}",'invalid level index') end)
check('level scalar rejection',function() rejected("ability{id='ANEW',parent='AHbz',fields={alev=2,acdn=4}}",'dense level table') end)
check('missing ability levels',function() rejected("ability{id='ANEW',parent='AHbz',fields={anam='x'}}",'requires alev') end)
check('duplicate declaration conflict',function() rejected("unit{id='uNEW',parent='hfoo',fields={}} unit{id='uNEW',parent='hfoo',fields={}}",'duplicate object id') end)
check('existing custom collision',function() rejected("unit{id='uO11',parent='hfoo',fields={}}",'object id collision') end)
check('standard id collision',function() rejected("unit{id='hpea',parent='hfoo',fields={}}",'object id collision') end)
check('validation atomic across kinds',function() rejected("unit{id='uNEW',parent='hfoo',fields={unam='ok'}} ability{id='ANEW',parent='AHbz',fields={alev=2,amcs={'bad',2}}}",'expects finite number') end)
check('existing original and custom bytes preserved',function()
    -- Include an original-object modification in addition to the generated custom one.
    local original='hpea'..'\0\0\0\0'..string.pack('<i4',1)..'uhpm'..string.pack('<i4i4',0,999)..'\0\0\0\0'
    local baseline=string.pack('<i4i4',2,1)..original..firstU:sub(9)
    write(u,baseline)
    compile("unit{id='uNEW',parent='hfoo',fields={unam='Added'}}")
    local result=read(u)
    assert(result:sub(1,8+#original)==baseline:sub(1,8+#original))
    local count,p=string.unpack('<i4',result,9+#original); assert(count==2)
    assert(result:sub(p,p+#firstU-13)==firstU:sub(13))
    assert(read(a)==firstA)
end)
check('existing ability bytes preserved on append',function()
    local before=compiler.existing(read(a),true)
    compile("ability{id='ANEW',parent='AHbz',fields={alev=2,acdn={2,1}}}")
    local after=compiler.existing(read(a),true)
    assert(after.count==before.count+1 and before.original==after.original)
    assert(after.custom:sub(1,#before.custom)==before.custom)
end)
check('version 1 base header retained',function()
    write(u,string.pack('<i4i4i4',1,0,0))
    compile("unit{id='uABC',parent='hfoo',fields={unam='Version one'}}")
    assert(string.unpack('<i4',read(u))==1)
end)
check('unresolved LNI refuses ambiguous input',function()
    write(u..'.ini','[uOLD]\n_parent="hfoo"\n')
    rejected("unit{id='uABC',parent='hfoo',fields={}}",'uncompiled LNI')
    os.remove(u..'.ini')
end)
check('unsupported existing version',function()
    write(u,string.pack('<i4i4i4',3,0,0))
    rejected("unit{id='uABC',parent='hfoo',fields={}}",'unsupported existing object version')
end)
check('declaration captures reused tables and level values',function()
    clear()
    compile([[local options={id='uA11',parent='hfoo',fields={unam='First'}}
unit(options)
options.id='uA12'; options.fields.unam='Second'; unit(options)
local cooldown={9,5}
ability{id='AA11',parent='AHbz',fields={alev=2,acdn=cooldown}}
cooldown[1]=2
ability{id='AA12',parent='AHbz',fields={alev=2,acdn=cooldown}}]])
    local units=compiler.existing(read(u),false)
    assert(units.count==2 and units.ids.uA11 and units.ids.uA12)
    assert(read(u):find('First',1,true) and read(u):find('Second',1,true))
    local abilities=compiler.existing(read(a),true)
    assert(abilities.count==2 and abilities.ids.AA11 and abilities.ids.AA12)
    assert(read(a):find(string.pack('<f',9),1,true),'earlier level table was mutated')
end)
-- Leave pristine generated files for the independent converter roundtrip.
clear(); compiler.compile(root..'/examples/11-object-data/objects.lua',scratch,data)
print(string.format('Results: %d passed, 0 failed, %d total',pass,pass))
