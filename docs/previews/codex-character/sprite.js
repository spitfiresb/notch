/* Original code-native 20 × 24 sprite study. Coordinates are portable to SwiftUI Canvas.
   No raster reference/image is traced at runtime; body and expressions use flat pixel cells. */
window.CodexDude=(()=>{
const C={outline:'#222747',shadow:'#3d4d9a',blue:'#607ce0',light:'#88a7ff',shine:'#a1bbff',screen:'#252c59',cyan:'#b4f2f4',amber:'#ffd18a',red:'#ff9fad'};
function draw(ctx,x,y,height,state,t){ctx.save();const p=height/24;ctx.translate(x,y);ctx.scale(p,p);ctx.imageSmoothingEnabled=false;
let run=['running','complete'].includes(state),f=Math.floor(t/.085)%4,bob=run?(f%2?-.5:0):state==='thinking'?Math.sin(t*3)*.35:0;
if(state==='permission'){const q=t%.7/.7;bob=q<.35?-2*Math.sin(q/.35*Math.PI):0}
if(state==='question'){ctx.translate(10,20);ctx.rotate(Math.sin(t/ .9*Math.PI*2)*.10);ctx.translate(-10,-20)}
if(state==='compacting'){let k=1-Math.max(0,Math.sin(t*3))*.06;ctx.translate(0,24*(1-k));ctx.scale(1,k)}
if(state==='failed'){let a=Math.min(1,(t%6.3)/.4);ctx.translate(15,20);ctx.rotate(Math.PI/2*a);ctx.translate(-15,-20)}
ctx.translate(0,bob);
const r=(x,y,w,h,c)=>{ctx.fillStyle=C[c]||c;ctx.fillRect(x,y,w,h)};
// Oversized scalloped head, with a single dark outline and restrained stepped highlight.
const spans=[[6,4],[4,10],[3,13],[2,15],[1,17],[0,19],[0,20],[0,20],[0,20],[1,18],[1,18],[2,16],[3,14],[4,12]];
spans.forEach(([a,w],j)=>r(a,j,w,1,'outline'));
r(12,0,3,1,'outline');r(11,1,5,1,'outline');
const fills=[[6,4],[4,10],[3,13],[2,15],[1,17],[1,18],[1,18],[1,18],[2,16],[2,16],[3,14],[4,12]];
fills.forEach(([a,w],j)=>r(a,j+1,w,1,j<3?'light':j>9?'shadow':'blue'));
r(12,1,3,1,'light');r(5,1,5,1,'shine');r(12,2,2,1,'shine');r(2,5,1,4,'light');r(17,6,1,4,'shadow');r(4,12,12,1,'shadow');
// Screen bezel and its dark, flat glass.
r(5,5,10,1,'outline');r(4,6,12,6,'outline');r(5,6,10,5,'screen');r(5,6,1,1,'shadow');
let face=['failed','ko'].includes(state)?'ko':state;
if(face==='ko'){for(let a of [6,11]){r(a,7,1,1,'red');r(a+2,7,1,1,'red');r(a+1,8,1,1,'red');r(a,9,1,1,'red');r(a+2,9,1,1,'red')}}
else if(face==='permission'){r(9,6,2,3,'amber');r(9,10,2,1,'amber')}
else if(face==='question'){r(8,6,3,1,'cyan');r(11,7,1,1,'cyan');r(9,8,2,1,'cyan');r(9,10,1,1,'cyan')}
else if(face==='done'||face==='complete'){r(6,7,2,1,'cyan');r(12,7,2,1,'cyan');r(8,9,4,1,'cyan');r(7,8,1,1,'cyan');r(12,8,1,1,'cyan')}
else if(face==='compacting'){for(let i=0;i<3;i++)r(6+i*3,8,2,1,Math.floor(t*5)%3===i?'cyan':'shadow')}
else if(face==='interrupted'){r(7,8,6,1,'shadow')}
else if(face==='idle'&&t%4>3.75){r(6,8,3,1,'cyan');r(11,8,3,1,'cyan')}
else{r(6,7,1,1,'cyan');r(7,8,1,1,'cyan');r(6,9,1,1,'cyan');if(face!=='thinking'||Math.floor(t*2)%2===0)r(11,9,3,1,'cyan')}
// Neck, compact sweatshirt, one-pixel seam.
r(7,14,6,1,'outline');r(6,15,8,5,'outline');r(7,15,6,4,'blue');r(7,15,6,1,'light');r(8,19,4,1,'shadow');
r(8,16,1,1,'cyan');r(9,17,1,1,'cyan');r(8,18,1,1,'cyan');r(11,18,1,1,'cyan');
// Arms detach from the silhouette on each stride, keeping the tiny pose legible.
let left=run?(f<2?-1:1):0,right=run?(f<2?1:-1):0;
r(4,15+left,2,5,'outline');r(4,16+left,1,3,'blue');r(3,18+left,2,2,'outline');r(3,18+left,1,1,'light');
r(14,15+right,2,5,'outline');r(15,16+right,1,3,'blue');r(15,18+right,2,2,'outline');r(16,18+right,1,1,'light');
let l=run?(f<2?-1:1):0,rr=run?(f<2?1:-1):0;
r(6+l,20,3,3,'outline');r(6+l,20,2,2,'blue');r(5+l,22,4,1,'outline');r(5+l,21,1,1,'shadow');
r(11+rr,20,3,3,'outline');r(12+rr,20,2,2,'blue');r(11+rr,22,4,1,'outline');r(14+rr,21,1,1,'shadow');
// Floating speech pixels preserve Claude's permission/question choreography.
if(state==='permission'&&Math.floor(t/.35)%2===0){r(9,-6,2,3,'amber');r(9,-2,2,1,'amber')}
if(state==='question'){r(8,-6,3,1,'cyan');r(11,-5,1,1,'cyan');r(9,-4,2,1,'cyan');r(9,-2,1,1,'cyan')}
ctx.restore();}
return {draw,palette:C,width:20,height:24};})();
