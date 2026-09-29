'use strict';
const assert=require('node:assert/strict');
const mod=require('./WCRechargeIOS/Resources/login-context.js');
let checks=0;
const credential='openid=TEST_GAME_ID&openkey=TEST_GAME_KEY&sessiontype=wc_actoken&sessionid=hy_gameid';
const qq='12345678';
const cookie=(name,value,domain='qq.com',extra={})=>({name,value,domain,path:'/',hostOnly:false,expiresAt:Date.now()+600000,...extra});
const base=[cookie('uin','o0012345678'),cookie('skey','TEST_SKEY'),cookie('p_uin','o12345678','pay.qq.com'),cookie('p_skey','PAY_KEY','pay.qq.com'),cookie('p_skey','OTHER_KEY','xinyue.qq.com'),cookie('pay-extra','EXTRA','pay.qq.com',{httpOnly:true,sameSite:'None'})];
const configs=['https://pay.qq.com/h5/index.shtml?rebate=keep','https://scp.qq.com/payr/jump.html?rebate=keep','https://xinyue.qq.com/test?rebate=keep'];
for(const platform of ['android','ios'])for(const url of configs){
 const p=mod.build({type:'充值官网',url,browserPlatform:platform,payerQQ:qq},credential,base);
 assert.equal(p.payerQQ,qq);assert.equal(p.cookies.length,8);
 assert.deepEqual(p.sourceCookies,base);
 for (const name of ["uin","skey","p_uin","p_skey"]) assert.ok(p.cookies.some(r=>r.name===name&&r.domain==="pay.qq.com"&&!r.hostOnly));
 assert.equal(p.cookies.find(r=>r.name==='p_skey'&&r.domain==='pay.qq.com').value,'PAY_KEY');
 assert.equal(p.cookies.find(r=>r.name==='p_skey'&&r.domain==='xinyue.qq.com').value,'OTHER_KEY');
 assert.equal(p.cookies.find(r=>r.name==='pay-extra').httpOnly,true);
 assert.equal(new URL(p.url).searchParams.get('rebate'),'keep');
 if(url.includes('pay.qq.com/h5'))assert.equal(new URL(p.url).searchParams.get('openid'),'TEST_GAME_ID');
 else {assert.equal(p.url,url);assert.equal(p.deferCkInjection,true);assert.equal(p.beforeWarmup.find(r=>r.name==='access_token').value,'TEST_GAME_KEY');}
 checks++;
}
const cfg={type:'充值官网',url:configs[0],payerQQ:qq};
for(const bad of [[],{},base.map(r=>({...r,expiresAt:1})),base.map(r=>r.name==='uin'?{...r,value:'o98765432'}:r),[cookie('uin','o12345678')],[cookie('uin','o12345678','xinyue.qq.com'),cookie('skey','X','xinyue.qq.com')]]){
 assert.throws(()=>mod.build(cfg,credential,bad));checks++;
}
const hostOnly=base.map(r=>r.name==='skey'?{...r,hostOnly:true}:r).filter(r=>r.name!=='p_skey');
assert.throws(()=>mod.build(cfg,credential,hostOnly));checks++;
const original=JSON.stringify(base);mod.build(cfg,credential,base);assert.equal(JSON.stringify(base),original);checks++;
for(let i=0;i<100;i++){
 const expected=i%2?'12345678':'87654321';
 const p=mod.build({...cfg,payerQQ:expected},credential,[cookie('uin','o'+expected),cookie('skey','KEY_'+expected)]);
 assert.equal(p.cookies.find(r=>r.name==='uin').value,'o'+expected);
 assert.equal(p.cookies.find(r=>r.name==='skey').value,'KEY_'+expected);
}checks++;
console.log(`PASS ${checks} login-plan cases (including 100 alternating accounts; offline only)`);

const scopedOnly=[cookie('uin','o12345678','pay.qq.com',{hostOnly:true}),cookie('skey','HOST_KEY','pay.qq.com',{hostOnly:true})];
const scopePlan=mod.build(cfg,credential,scopedOnly);
assert.ok(scopePlan.cookies.every(r=>r.domain==='pay.qq.com'&&!r.hostOnly));
assert.ok(scopedOnly.every(r=>r.hostOnly));
assert.deepEqual(scopePlan.sourceCookies,scopedOnly);
console.log('PASS host-only payer credentials receive a pay.qq.com family scope; original snapshot unchanged');
