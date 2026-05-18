// DEFUNCT.

import { useState, useEffect, useRef } from "react";
import * as THREE from "three";
 
// ── LORD DATA ─────────────────────────────────────────────────────────────────
const LORDS = [
  { id:0,  short:"H·III",  name:"Henry III",            title:"King of England",      faction:"england", martial:5, diplomacy:7, stewardship:6 },
  { id:1,  short:"Mowbr",  name:"William de Mowbray",   title:"Earl of York",         faction:"england", martial:7, diplomacy:4, stewardship:5 },
  { id:2,  short:"Blond",  name:"Ranulf de Blondeville", title:"Earl of Lancaster",    faction:"england", martial:6, diplomacy:6, stewardship:7 },
  { id:3,  short:"Burgh",  name:"Hubert de Burgh",      title:"Earl of Kent",         faction:"england", martial:4, diplomacy:8, stewardship:6 },
  { id:4,  short:"Bigod",  name:"Roger Bigod",          title:"Earl of Norfolk",      faction:"england", martial:8, diplomacy:3, stewardship:4 },
  { id:5,  short:"Clare",  name:"Gilbert de Clare",     title:"Earl of Oxford",       faction:"england", martial:6, diplomacy:5, stewardship:6 },
  { id:6,  short:"Lacy",   name:"John de Lacy",         title:"Earl of Lincoln",      faction:"england", martial:5, diplomacy:7, stewardship:8 },
  { id:7,  short:"Braos",  name:"Reginald de Braose",   title:"Lord of Bristol",      faction:"england", martial:7, diplomacy:2, stewardship:4 },
  { id:8,  short:"L·IX",   name:"Louis IX",             title:"King of France",       faction:"france",  martial:7, diplomacy:8, stewardship:7 },
  { id:9,  short:"Lusig",  name:"Hugh de Lusignan",     title:"Count of Poitou",      faction:"france",  martial:6, diplomacy:5, stewardship:5 },
  { id:10, short:"Raym·",  name:"Raymond VII",          title:"Count of Toulouse",    faction:"france",  martial:7, diplomacy:6, stewardship:6 },
  { id:11, short:"Dreux",  name:"Peter of Dreux",       title:"Duke of Brittany",     faction:"france",  martial:5, diplomacy:7, stewardship:7 },
  { id:12, short:"Alex·",  name:"Alexander II",         title:"King of Scotland",     faction:"scotland",martial:6, diplomacy:5, stewardship:6 },
  { id:13, short:"Gall·",  name:"Alan of Galloway",     title:"Lord of Galloway",     faction:"scotland",martial:8, diplomacy:3, stewardship:4 },
];
const N = LORDS.length;
 
// ── RELATIONSHIP MATRIX ───────────────────────────────────────────────────────
const buildMatrix = () => {
  const m = Array.from({length:N}, () => Array(N).fill(null));
  const set = (a, b, val, reason) => { m[a][b] = {val,reason}; m[b][a] = {val,reason}; };
  // England internal
  set(0,1,-30,"Border tax dispute unresolved since 1239");
  set(0,2, 25,"Lancaster provides reliable scutage payments");
  set(0,3, 65,"Burgh served loyally as Justiciar for two decades");
  set(0,4,-15,"Bigod refused the last royal army summons");
  set(0,5, 45,"Clare's daughter betrothed to the royal cousin");
  set(0,6, 20,"Lacy — dutiful, but quietly ambitious");
  set(0,7,-55,"The Braose family carries a history of treason");
  set(1,2,-80,"Bitter feud over the Ribble Valley inheritance");
  set(1,3, 35,"Both oppose growing royal centralization");
  set(1,4, 55,"Old campaign companions from the Welsh marches");
  set(1,5,-25,"Clare encroaches upon Mowbray's hunting rights");
  set(1,6, 15,"Neutral — occasional grain trade");
  set(1,7, 20,"United in their distrust of the Crown");
  set(2,3,-45,"Long-standing rivals for the Justiciarship");
  set(2,4, 35,"Allies in the baronial council");
  set(2,5, 60,"Close friendship forged on Crusade in 1244");
  set(2,6, 70,"Cousins by marriage — deeply loyal");
  set(2,7,-20,"Lancaster considers Braose a disreputable ally");
  set(3,4, 20,"Mutual respect, but no warmth");
  set(3,5,-30,"Burgh blocked Clare's wool market charter");
  set(3,6, 40,"Lacy publicly supported Burgh in council");
  set(3,7,-60,"Burgh had Braose's father imprisoned in 1228");
  set(4,5, 50,"Tournament companions, frequent correspondence");
  set(4,6, 30,"Mild regional alliance");
  set(4,7, 10,"Neutral acquaintance");
  set(5,6, 45,"Shared Oxford scholarly and trade interests");
  set(5,7,-10,"Mild distrust over Bristol wool prices");
  set(6,7, 25,"Profitable trade arrangement");
  // France internal
  set(8, 9,-45,"Lusignan claims Poitou was seized illegally");
  set(8,10, 25,"Toulouse submits, but grudgingly");
  set(8,11, 65,"Brittany — the crown's most loyal vassal");
  set(9,10, 50,"United against Parisian centralization");
  set(9,11,-35,"Maritime trade rivalry in the Channel");
  set(10,11, 15,"Neutral, distant acquaintance");
  // Scotland internal
  set(12,13,-20,"Galloway actively resists royal authority");
  // Cross-faction
  set(0, 8,-70,"Hereditary enemies — wars of succession");
  set(1, 9,-25,"Mowbray raided Lusignan lands in Gascony");
  set(2,11,-30,"Lancaster blockades Breton Channel fishing");
  set(7, 9, 35,"SECRET — Braose receives French gold");
  set(0,12,-40,"Scotland raids the northern English border");
  set(1,13,-60,"Galloway burned Mowbray's border villages in 1241");
  set(12, 8, 45,"Auld Alliance — Scotland and France stand together");
  set(4, 10,-20,"Bigod seized Toulouse merchants at Bristol");
  return m;
};
const MATRIX = buildMatrix();
 
// ── HELPERS ───────────────────────────────────────────────────────────────────
const FC = { england:"#b22222", france:"#1a4f8a", scotland:"#2e7d32" };
const FD = { england:"#7b1a1a", france:"#0f2d52", scotland:"#1b5e20" };
const FA = { england:"rgba(178,34,34,0.15)", france:"rgba(26,79,138,0.15)", scotland:"rgba(46,125,50,0.15)" };
 
function valToColor(v) {
  if (v === null) return '#1a1813';
  if (v > 60)  return '#145a32';
  if (v > 30)  return '#1e8449';
  if (v > 10)  return '#27ae60';
  if (v > -10) return '#3a3530';
  if (v > -30) return '#784212';
  if (v > -60) return '#a93226';
  return '#7b241c';
}
function valToLabel(v) {
  if (v >  60) return "Sworn Ally";
  if (v >  30) return "Friendly";
  if (v >  10) return "Cordial";
  if (v > -10) return "Neutral";
  if (v > -30) return "Cool";
  if (v > -60) return "Hostile";
  return "Bitter Enemy";
}
function valToTextColor(v) {
  if (Math.abs(v) > 25) return '#e8d5b0';
  return '#8a7a65';
}
 
// ── 3D POSITIONS ──────────────────────────────────────────────────────────────
function getLordPosition(lord) {
  const engLords = LORDS.filter(l => l.faction==='england');
  const frLords  = LORDS.filter(l => l.faction==='france');
  const scLords  = LORDS.filter(l => l.faction==='scotland');
  if (lord.faction === 'england') {
    const i = engLords.indexOf(lord);
    const t = (i / engLords.length) * Math.PI * 2;
    return new THREE.Vector3(-7 + Math.cos(t)*5, Math.sin(t)*5, Math.sin(t*0.7)*2);
  }
  if (lord.faction === 'france') {
    const i = frLords.indexOf(lord);
    const t = (i / frLords.length) * Math.PI * 2;
    return new THREE.Vector3(7 + Math.cos(t)*4, Math.sin(t)*4, Math.sin(t*0.7)*2);
  }
  const i = scLords.indexOf(lord);
  return new THREE.Vector3(-4 + i*4, 10, 0);
}
 
// ── COMPONENT ─────────────────────────────────────────────────────────────────
export default function AllegianceMatrix() {
  const [tab, setTab]           = useState('matrix');
  const [selCell, setSelCell]   = useState(null);   // {a,b}
  const [selLord, setSelLord]   = useState(null);   // lord id
  const [hoverRow, setHoverRow] = useState(null);
  const mountRef  = useRef(null);
  const cleanupFn = useRef(null);
 
  // ── 3D SCENE ────────────────────────────────────────────────────────────────
  useEffect(() => {
    if (tab !== 'web') { if(cleanupFn.current) { cleanupFn.current(); cleanupFn.current=null; } return; }
    if (!mountRef.current) return;
 
    const el = mountRef.current;
    const W = el.clientWidth, H = el.clientHeight;
    const renderer = new THREE.WebGLRenderer({ antialias:true });
    renderer.setSize(W, H);
    renderer.setPixelRatio(window.devicePixelRatio);
    renderer.setClearColor(0x0a0906, 1);
    el.appendChild(renderer.domElement);
 
    const scene  = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(55, W/H, 0.1, 200);
    camera.position.set(0, 0, 28);
 
    scene.add(new THREE.AmbientLight(0xfff8e7, 0.7));
    const sun = new THREE.DirectionalLight(0xffe4b5, 1.2);
    sun.position.set(10, 15, 10);
    scene.add(sun);
    const rim = new THREE.DirectionalLight(0x4a90d9, 0.4);
    rim.position.set(-10, -5, -10);
    scene.add(rim);
 
    // Rotation group
    const group = new THREE.Group();
    scene.add(group);
 
    const positions = LORDS.map(getLordPosition);
 
    // Nodes
    LORDS.forEach((lord, i) => {
      const isKing = lord.title.startsWith('King');
      const r = isKing ? 0.55 : 0.38;
      const geo = new THREE.SphereGeometry(r, 20, 20);
      const col = new THREE.Color(FC[lord.faction]);
      const mat = new THREE.MeshPhongMaterial({
        color: col,
        emissive: col.clone().multiplyScalar(0.3),
        shininess: 120,
        specular: new THREE.Color(0xffffff),
      });
      const mesh = new THREE.Mesh(geo, mat);
      mesh.position.copy(positions[i]);
      group.add(mesh);
 
      // Ring for kings
      if (isKing) {
        const ringGeo = new THREE.TorusGeometry(0.72, 0.06, 8, 32);
        const ringMat = new THREE.MeshPhongMaterial({ color:0xc9973d, emissive:0x7a5a1a });
        const ring = new THREE.Mesh(ringGeo, ringMat);
        ring.position.copy(positions[i]);
        group.add(ring);
      }
    });
 
    // Relationship lines
    LORDS.forEach((_, i) => {
      LORDS.forEach((__, j) => {
        if (j <= i) return;
        const rel = MATRIX[i][j];
        if (!rel) return;
        const v = rel.val;
        if (Math.abs(v) < 10) return;
 
        const pts = [positions[i].clone(), positions[j].clone()];
        const geo = new THREE.BufferGeometry().setFromPoints(pts);
 
        let col;
        if (v > 0)  col = new THREE.Color(0x27ae60).lerp(new THREE.Color(0x82e0aa), v/100);
        else        col = new THREE.Color(0x6e1010).lerp(new THREE.Color(0xe74c3c), Math.abs(v)/100);
 
        const mat = new THREE.LineBasicMaterial({
          color: col,
          transparent: true,
          opacity: (Math.abs(v)/100)*0.75 + 0.15,
        });
        group.add(new THREE.Line(geo, mat));
      });
    });
 
    // Faction label planes (billboarded sprites)
    ['england','france','scotland'].forEach(f => {
      const lInGroup = LORDS.filter(l => l.faction === f);
      const cx = lInGroup.reduce((s,l,i) => s + positions[LORDS.indexOf(l)].x, 0) / lInGroup.length;
      const cy = lInGroup.reduce((s,l,i) => s + positions[LORDS.indexOf(l)].y, 0) / lInGroup.length;
    });
 
    // Mouse rotation
    let dragging=false, lastX=0, lastY=0;
    const onDown = e => { dragging=true; lastX=e.clientX; lastY=e.clientY; };
    const onMove = e => {
      if (!dragging) return;
      group.rotation.y += (e.clientX - lastX) * 0.008;
      group.rotation.x += (e.clientY - lastY) * 0.008;
      lastX=e.clientX; lastY=e.clientY;
    };
    const onUp = () => { dragging=false; };
    renderer.domElement.addEventListener('mousedown', onDown);
    window.addEventListener('mousemove', onMove);
    window.addEventListener('mouseup', onUp);
 
    // Animation
    let animId;
    const tick = () => {
      animId = requestAnimationFrame(tick);
      if (!dragging) group.rotation.y += 0.0015;
      renderer.render(scene, camera);
    };
    tick();
 
    cleanupFn.current = () => {
      cancelAnimationFrame(animId);
      renderer.domElement.removeEventListener('mousedown', onDown);
      window.removeEventListener('mousemove', onMove);
      window.removeEventListener('mouseup', onUp);
      if (el.contains(renderer.domElement)) el.removeChild(renderer.domElement);
      renderer.dispose();
    };
    return () => { if(cleanupFn.current){ cleanupFn.current(); cleanupFn.current=null; } };
  }, [tab]);
 
  // ── DERIVED STATE ────────────────────────────────────────────────────────────
  const selRel   = selCell ? MATRIX[selCell.a][selCell.b] : null;
  const lordRels = selLord !== null
    ? LORDS.map((l,i) => i===selLord ? null : ({ lord:l, rel:MATRIX[selLord][i] }))
        .filter(Boolean)
        .filter(x => x.rel)
        .sort((a,b) => b.rel.val - a.rel.val)
    : [];
 
  // ── RENDER ───────────────────────────────────────────────────────────────────
  return (
    <div style={{ fontFamily:"'Palatino Linotype','Book Antiqua',Palatino,Georgia,serif", background:"#0a0906", minHeight:"100vh", color:"#d4b896", display:"flex", flexDirection:"column" }}>
 
      {/* ── HEADER ── */}
      <div style={{ padding:"18px 24px 0", borderBottom:"1px solid #3a3020" }}>
        <div style={{ fontSize:11, letterSpacing:4, color:"#7a6a55", textTransform:"uppercase", marginBottom:4 }}>
          The Chronicle of Allegiances · Anno Domini 1247
        </div>
        <div style={{ fontSize:22, color:"#c9973d", letterSpacing:1 }}>
          The Web of Lords
        </div>
 
        {/* Tabs */}
        <div style={{ display:"flex", gap:0, marginTop:14 }}>
          {[['matrix','The Matrix'],['web','The Web (3D)']].map(([id,label]) => (
            <button key={id} onClick={() => setTab(id)} style={{
              background: tab===id ? '#1e1a14' : 'transparent',
              border:'none', borderBottom: tab===id ? '2px solid #c9973d' : '2px solid transparent',
              color: tab===id ? '#c9973d' : '#7a6a55', padding:"8px 18px",
              cursor:'pointer', fontSize:13, letterSpacing:1, fontFamily:'inherit',
              transition:'all 0.2s'
            }}>{label}</button>
          ))}
        </div>
      </div>
 
      {/* ── LEGEND ── */}
      <div style={{ display:"flex", gap:6, padding:"10px 24px", alignItems:"center", flexWrap:"wrap", borderBottom:"1px solid #2a2318" }}>
        <span style={{fontSize:10,color:"#5a5048",letterSpacing:2,textTransform:"uppercase",marginRight:6}}>Allegiance</span>
        {[['Sworn Ally','#145a32'],['Friendly','#1e8449'],['Cordial','#27ae60'],['Neutral','#3a3530'],['Cool','#784212'],['Hostile','#a93226'],['Bitter Enemy','#7b241c']].map(([label,bg]) => (
          <div key={label} style={{display:"flex",alignItems:"center",gap:4}}>
            <div style={{width:12,height:12,borderRadius:2,background:bg}}/>
            <span style={{fontSize:10,color:"#7a6a55"}}>{label}</span>
          </div>
        ))}
        <div style={{marginLeft:'auto', display:"flex", gap:12}}>
          {Object.entries(FC).map(([f,c]) => (
            <div key={f} style={{display:"flex",alignItems:"center",gap:5}}>
              <div style={{width:8,height:8,borderRadius:"50%",background:c}}/>
              <span style={{fontSize:10,color:"#7a6a55",textTransform:"capitalize"}}>{f}</span>
            </div>
          ))}
        </div>
      </div>
 
      {/* ── MAIN CONTENT ── */}
      <div style={{ display:"flex", flex:1, overflow:"hidden" }}>
 
        {/* ── 2D MATRIX ── */}
        {tab === 'matrix' && (
          <div style={{ flex:1, overflow:"auto", padding:"20px 24px" }}>
            <div style={{ overflowX:"auto" }}>
              <table style={{ borderCollapse:"collapse", fontSize:11 }}>
                <thead>
                  <tr>
                    <th style={{ width:90, minWidth:90 }}/>
                    {LORDS.map(l => (
                      <th key={l.id} style={{ width:42, padding:"0 1px 8px", textAlign:"center", cursor:"pointer" }}
                        onClick={() => setSelLord(selLord===l.id ? null : l.id)}>
                        <div style={{ writingMode:"vertical-rl", transform:"rotate(180deg)",
                          color: selLord===l.id ? '#c9973d' : FC[l.faction],
                          fontWeight: selLord===l.id ? 700 : 400,
                          fontSize: 10.5, letterSpacing:0.5, whiteSpace:"nowrap",
                          padding:"4px 2px", borderBottom: selLord===l.id ? `2px solid ${FC[l.faction]}` : '2px solid transparent',
                        }}>
                          {l.short}
                        </div>
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {LORDS.map((rowLord, i) => (
                    <tr key={i} onMouseEnter={() => setHoverRow(i)} onMouseLeave={() => setHoverRow(null)}>
                      <td style={{ paddingRight:10, textAlign:"right", whiteSpace:"nowrap",
                        color: selLord===i ? '#c9973d' : hoverRow===i ? '#d4b896' : FC[rowLord.faction],
                        fontWeight: selLord===i ? 700 : 400, cursor:"pointer", fontSize:10.5,
                        paddingBottom:2, paddingTop:2
                      }} onClick={() => setSelLord(selLord===i ? null : i)}>
                        {rowLord.short}
                      </td>
                      {LORDS.map((colLord, j) => {
                        const rel    = MATRIX[i][j];
                        const isself = i === j;
                        const issel  = selCell && ((selCell.a===i&&selCell.b===j)||(selCell.a===j&&selCell.b===i));
                        const highlighted = selLord === i || selLord === j || hoverRow === i;
                        const v = rel ? rel.val : null;
                        const bg = isself ? '#141210' : valToColor(v);
                        return (
                          <td key={j}
                            onClick={() => !isself && setSelCell(issel ? null : {a:i,b:j})}
                            style={{
                              width:40, height:34, textAlign:"center",
                              background: isself ? '#141210' : bg,
                              cursor: isself ? 'default' : 'pointer',
                              border: issel ? '2px solid #c9973d'
                                : (highlighted && !isself) ? '1px solid rgba(201,151,61,0.4)'
                                : '1px solid #1e1a14',
                              borderRadius:2,
                              opacity: selLord !== null && !highlighted ? 0.35 : 1,
                              transition:'all 0.15s',
                              position:'relative',
                            }}>
                            {!isself && v !== null && (
                              <span style={{
                                fontSize:9.5, fontWeight:600,
                                color: valToTextColor(v),
                                userSelect:'none'
                              }}>
                                {v > 0 ? '+' : ''}{v}
                              </span>
                            )}
                            {isself && <span style={{color:'#2a2520',fontSize:11}}>✕</span>}
                          </td>
                        );
                      })}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}
 
        {/* ── 3D WEB ── */}
        {tab === 'web' && (
          <div style={{ flex:1, position:"relative" }}>
            <div ref={mountRef} style={{ width:"100%", height:"100%" }}/>
            <div style={{ position:"absolute", bottom:16, left:16, fontSize:10, color:"#5a5048", letterSpacing:1, textTransform:"uppercase" }}>
              Drag to rotate · Line weight = bond strength
            </div>
            <div style={{ position:"absolute", top:16, left:16, display:"flex", flexDirection:"column", gap:6 }}>
              {[['england','England'],['france','France'],['scotland','Scotland']].map(([f,label]) => (
                <div key={f} style={{ display:"flex", alignItems:"center", gap:8 }}>
                  <div style={{ width:10, height:10, borderRadius:"50%", background:FC[f], boxShadow:`0 0 6px ${FC[f]}` }}/>
                  <span style={{ fontSize:11, color:"#7a6a55", letterSpacing:1 }}>{label}</span>
                </div>
              ))}
              <div style={{ marginTop:8, borderTop:"1px solid #2a2318", paddingTop:8 }}>
                <div style={{display:"flex",alignItems:"center",gap:8,marginBottom:4}}>
                  <div style={{width:24,height:2,background:"#27ae60"}}/>
                  <span style={{fontSize:10,color:"#7a6a55"}}>Allied</span>
                </div>
                <div style={{display:"flex",alignItems:"center",gap:8}}>
                  <div style={{width:24,height:2,background:"#e74c3c"}}/>
                  <span style={{fontSize:10,color:"#7a6a55"}}>Hostile</span>
                </div>
              </div>
            </div>
          </div>
        )}
 
        {/* ── RIGHT PANEL ── */}
        <div style={{ width:280, borderLeft:"1px solid #2a2318", padding:"20px 16px", overflowY:"auto", flexShrink:0 }}>
 
          {/* Lord profile */}
          {selLord !== null && (() => {
            const lord = LORDS[selLord];
            return (
              <div style={{ marginBottom:20 }}>
                <div style={{ fontSize:9, letterSpacing:3, color:"#5a5048", textTransform:"uppercase", marginBottom:6 }}>Selected Lord</div>
                <div style={{ background: FA[lord.faction], border:`1px solid ${FC[lord.faction]}33`, borderRadius:4, padding:"12px 14px" }}>
                  <div style={{ fontSize:15, color: FC[lord.faction], marginBottom:2 }}>{lord.name}</div>
                  <div style={{ fontSize:11, color:"#7a6a55", marginBottom:10 }}>{lord.title}</div>
                  <div style={{ display:"grid", gridTemplateColumns:"1fr 1fr 1fr", gap:8, marginBottom:12 }}>
                    {[['Martial',lord.martial],['Diplomacy',lord.diplomacy],['Stewardship',lord.stewardship]].map(([k,v]) => (
                      <div key={k} style={{ textAlign:"center" }}>
                        <div style={{ fontSize:16, color:"#c9973d", fontWeight:700 }}>{v}</div>
                        <div style={{ fontSize:9, color:"#5a5048", letterSpacing:1 }}>{k.toUpperCase()}</div>
                      </div>
                    ))}
                  </div>
                  <div style={{ fontSize:10, color:"#5a5048", letterSpacing:2, textTransform:"uppercase", marginBottom:6 }}>All Relations</div>
                  {lordRels.map(({lord:l, rel}) => (
                    <div key={l.id} onClick={() => setSelCell({a:selLord,b:l.id})}
                      style={{ display:"flex", alignItems:"center", gap:8, marginBottom:5, cursor:"pointer",
                        padding:"4px 6px", borderRadius:3,
                        background: selCell?.a===selLord && selCell?.b===l.id ? '#2a2318' : 'transparent' }}>
                      <div style={{ width:6, height:6, borderRadius:"50%", background: FC[l.faction], flexShrink:0 }}/>
                      <div style={{ flex:1, fontSize:10.5, color:"#a09080", whiteSpace:"nowrap", overflow:"hidden", textOverflow:"ellipsis" }}>
                        {l.short}
                      </div>
                      <div style={{ fontSize:10.5, fontWeight:700, color: rel.val > 0 ? '#27ae60' : rel.val < 0 ? '#e74c3c' : '#5a5048', minWidth:28, textAlign:"right" }}>
                        {rel.val > 0 ? '+' : ''}{rel.val}
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            );
          })()}
 
          {/* Relationship detail */}
          {selCell && (() => {
            const a = LORDS[selCell.a], b = LORDS[selCell.b];
            const rel = MATRIX[selCell.a][selCell.b];
            if (!rel) return null;
            const v = rel.val;
            return (
              <div>
                <div style={{ fontSize:9, letterSpacing:3, color:"#5a5048", textTransform:"uppercase", marginBottom:8 }}>Relationship</div>
                <div style={{ background:"#141210", border:`1px solid ${valToColor(v)}44`, borderRadius:4, padding:"14px" }}>
                  <div style={{ display:"flex", justifyContent:"space-between", alignItems:"flex-start", marginBottom:10 }}>
                    <div>
                      <div style={{ fontSize:11, color:FC[a.faction] }}>{a.short}</div>
                      <div style={{ fontSize:9, color:"#5a5048" }}>↕</div>
                      <div style={{ fontSize:11, color:FC[b.faction] }}>{b.short}</div>
                    </div>
                    <div style={{ textAlign:"right" }}>
                      <div style={{ fontSize:24, fontWeight:700, color: v>0?'#27ae60':v<0?'#e74c3c':'#5a5048' }}>
                        {v > 0 ? '+' : ''}{v}
                      </div>
                      <div style={{ fontSize:10, color:"#7a6a55" }}>{valToLabel(v)}</div>
                    </div>
                  </div>
 
                  {/* Bar */}
                  <div style={{ height:4, background:"#2a2318", borderRadius:2, marginBottom:12, position:"relative" }}>
                    <div style={{ position:"absolute", left:"50%", top:0, bottom:0, width:1, background:"#3a3020" }}/>
                    <div style={{
                      position:"absolute",
                      left: v >= 0 ? '50%' : `${50 + v/2}%`,
                      width: `${Math.abs(v)/2}%`,
                      top:0, bottom:0,
                      background: v > 0 ? '#27ae60' : '#e74c3c',
                      borderRadius:2, transition:"all 0.3s"
                    }}/>
                  </div>
 
                  <div style={{ fontSize:11, color:"#8a7a65", lineHeight:1.6, fontStyle:"italic", borderTop:"1px solid #2a2318", paddingTop:10 }}>
                    "{rel.reason}"
                  </div>
 
                  {/* Faction indicator */}
                  <div style={{ marginTop:10, display:"flex", gap:8 }}>
                    {[a,b].map(lord => (
                      <div key={lord.id} style={{ flex:1, textAlign:"center", padding:"6px 4px",
                        background: FA[lord.faction], borderRadius:3, border:`1px solid ${FC[lord.faction]}33` }}>
                        <div style={{ fontSize:10, color:FC[lord.faction] }}>{lord.faction.toUpperCase()}</div>
                        <div style={{ fontSize:9, color:"#5a5048" }}>{lord.short}</div>
                      </div>
                    ))}
                  </div>
                </div>
              </div>
            );
          })()}
 
          {!selLord && !selCell && (
            <div style={{ color:"#3a3020", fontSize:12, textAlign:"center", marginTop:40, lineHeight:2 }}>
              Click a lord's name<br/>to see their web<br/>of allegiances.<br/><br/>
              Click any cell<br/>to read the reason<br/>behind the bond.
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
 
