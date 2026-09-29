/* Shared, offline-testable login/link preparation. No network requests. */
(function (root) {
  'use strict';

  function fail(message) { throw new Error(message); }
  function safeDecode(value) {
    try { return decodeURIComponent(String(value || '').replace(/\+/g, '%20')); }
    catch (_) { return fail('登录信息或链接包含不完整的编码，请重新复制。'); }
  }
  function safeEncode(value) { return encodeURIComponent(String(value == null ? '' : value)); }

  function splitURL(raw) {
    if (typeof raw !== 'string') fail('充值链接无效。');
    var text = raw.trim();
    if (!text || /\s|[\x00-\x1f]/.test(text) || /%(?![a-f0-9]{2})/i.test(text)) fail('请使用完整、有效的 HTTPS 充值链接。');
    var m = /^(https):\/\/([a-z0-9.-]+)(?::443)?(\/[^?#]*)?(?:\?([^#]*))?(?:#(.*))?$/i.exec(text);
    if (!m) fail('请使用完整、有效的 HTTPS 充值链接。');
    var host = m[2].toLowerCase();
    if (host !== 'qq.com' && !/\.qq\.com$/.test(host)) fail('此链接不属于 QQ 站点，未向它传递登录信息。');
    if (host.indexOf('..') !== -1) fail('充值链接域名无效。');
    return {host:host, path:m[3] || '/', query:m[4] || '', fragment:m[5], origin:'https://' + host};
  }

  function parsePairs(raw) {
    var out = [];
    if (!raw) return out;
    String(raw).split('&').forEach(function (item) {
      if (!item) return;
      var at = item.indexOf('=');
      var rk = at < 0 ? item : item.slice(0, at);
      var rv = at < 0 ? '' : item.slice(at + 1);
      var key = safeDecode(rk).trim();
      if (!key) return;
      out.push({key:key, value:safeDecode(rv)});
    });
    return out;
  }

  function extractCredentialParams(text) {
    if (typeof text !== 'string' || !text.trim()) fail('请填写本人登录信息。');
    var raw = text.trim().replace(/&amp;/gi, '&');
    var all = [];
    var urlMatch = /https?:\/\/[^\s"'<>]+/i.exec(raw);
    var candidate = urlMatch ? urlMatch[0] : raw;

    var q = candidate.indexOf('?');
    if (q >= 0) {
      var after = candidate.slice(q + 1);
      var h = after.indexOf('#');
      all = all.concat(parsePairs(h >= 0 ? after.slice(0, h) : after));
      var frag = h >= 0 ? after.slice(h + 1) : '';
      var fq = frag.indexOf('?');
      if (fq >= 0) all = all.concat(parsePairs(frag.slice(fq + 1)));
    } else {
      var cleaned = candidate.replace(/^[?#&]+/, '').replace(/[;\s]+/g, '&');
      all = all.concat(parsePairs(cleaned));
    }

    // Fallback for copied text containing key=value snippets around labels/newlines.
    if (!all.length) {
      var re = /(?:^|[?&#;\s])([A-Za-z0-9_.-]+)=([^;&#\s]*)/g, m;
      while ((m = re.exec(raw))) all.push({key:m[1], value:safeDecode(m[2])});
    }

    var map = {}, order = [];
    all.forEach(function (p) {
      if (!p.key || /[\x00-\x20\x7f;]/.test(p.key) || /[\x00-\x1f\x7f;]/.test(p.value)) return;
      if (!Object.prototype.hasOwnProperty.call(map, p.key)) order.push(p.key);
      map[p.key] = p.value;
    });

    function first(keys) {
      for (var i=0;i<keys.length;i++) {
        var v = map[keys[i]];
        if (typeof v === 'string' && v.trim()) return v.trim();
      }
      return '';
    }
    var openid = first(['openid','open_id','pay_wechat_openid']);
    var openkey = first(['openkey','open_key','access_token','pay_wechat_access_token']);
    if (!openid || !openkey) fail('未找到完整的 openid 和 openkey。');

    // Keep every CK query field like the desktop implementation. Canonical fields are
    // added only when aliases were supplied, so the final URL is always usable.
    if (!Object.prototype.hasOwnProperty.call(map, 'openid')) { map.openid = openid; order.push('openid'); }
    if (!Object.prototype.hasOwnProperty.call(map, 'openkey')) { map.openkey = openkey; order.push('openkey'); }
    return {map:map, order:order, openid:openid, openkey:openkey};
  }

  function mergeIntoURL(rawUrl, parsed) {
    var u = splitURL(rawUrl), original = parsePairs(u.query), merged = {}, order = [];
    original.forEach(function (p) {
      if (!Object.prototype.hasOwnProperty.call(merged,p.key)) order.push(p.key);
      merged[p.key] = p.value;
    });
    parsed.order.forEach(function (key) {
      if (!Object.prototype.hasOwnProperty.call(merged,key)) order.push(key);
      merged[key] = parsed.map[key];
    });
    var query = order.map(function (key) { return safeEncode(key) + '=' + safeEncode(merged[key]); }).join('&');
    var finalUrl = u.origin + u.path + (query ? '?' + query : '') + (u.fragment !== undefined ? '#' + u.fragment : '');

    // Fail closed if any original parameter not explicitly overridden by CK was lost/changed.
    var check = splitURL(finalUrl), finalMap = {};
    parsePairs(check.query).forEach(function (p) { finalMap[p.key] = p.value; });
    for (var i=0;i<original.length;i++) {
      var op = original[i];
      if (!Object.prototype.hasOwnProperty.call(finalMap,op.key)) fail('返利参数校验失败，请重新保存链接。');
      if (!Object.prototype.hasOwnProperty.call(parsed.map,op.key) && finalMap[op.key] !== op.value) fail('返利参数校验失败，请重新保存链接。');
    }
    return finalUrl;
  }

  function cookieRows(saved, expectedQQ, reusePayer) {
    var rows = [], now = Date.now();
    if (!Array.isArray(saved)) fail('请重新扫码付款 QQ，旧版凭据缺少域名信息。');
    saved.forEach(function (row) {
      if (!row || !/^[A-Za-z0-9_!#$%&'*+.^`|~-]+$/.test(row.name || '') || row.name === 'qrsig') return;
      var value = row.value, domain = String(row.domain || '').replace(/^\./,'').toLowerCase();
      var path = row.path || '/';
      if (typeof value !== 'string' || !value || /[;\r\n\x00]/.test(value)) return;
      if (!/^(?:[a-z0-9-]+\.)*qq\.com$/.test(domain) || domain.indexOf('..') >= 0) return;
      if (typeof path !== 'string' || path.charAt(0) !== '/' || /[;\r\n\x00]/.test(path)) return;
      var expiresAt = Number(row.expiresAt || 0);
      if (!isFinite(expiresAt) || expiresAt < 0 || (!reusePayer && expiresAt && expiresAt <= now)) return;
      rows.push({name:row.name,value:value,domain:domain,path:path,
        hostOnly:!!row.hostOnly,secure:!!row.secure,httpOnly:!!row.httpOnly,
        sameSite:['None','Lax','Strict'].indexOf(row.sameSite) >= 0 ? row.sameSite : '',expiresAt:expiresAt});
    });
    function payValue(name) {
      var matching = rows.filter(function(r) {
        return r.name === name && r.path === '/' &&
          (r.domain === 'pay.qq.com' || (!r.hostOnly && 'pay.qq.com'.slice(-(r.domain.length+1)) === '.'+r.domain));
      });
      matching.sort(function(a,b) { return b.domain.length-a.domain.length; });
      return matching.length ? matching[0].value : '';
    }
    function qq(value) { return String(value || '').replace(/^o/i,'').replace(/^0+(?=\d)/,''); }
    if (!/^[0-9]{5,12}$/.test(String(expectedQQ || ''))) fail('请先选择付款 QQ。');
    var uin = qq(payValue('uin')), puin = qq(payValue('p_uin'));
    if ((!uin && !puin) || (uin && uin !== expectedQQ) || (puin && puin !== expectedQQ))
      fail('付款 QQ 凭据与所选账号不一致或已过期，请重新扫码。');
    if (!payValue('skey') && !payValue('p_skey')) fail('付款 QQ 凭据已过期，请重新扫码。');
    // Keep original saved scopes. Derive a payment-family view from the verified
    // pay.qq.com identity, so pagedoo/storeapi do not depend on a host-only cookie.
    // Unlike the desktop .qq.com injection, this compatibility scope is limited to pay.qq.com.
    ['uin','skey','p_uin','p_skey','pt4_token'].forEach(function(name) {
      var value = payValue(name);
      if (!value) return;
      var candidates = rows.filter(function(r) { return r.name === name && r.value === value && r.path === '/' &&
        (r.domain === 'pay.qq.com' || (!r.hostOnly && r.domain === 'qq.com')); });
      candidates.sort(function(a,b) { return b.domain.length-a.domain.length; });
      if (!candidates.length) return;
      var copy = Object.assign({}, candidates[0], {domain:'pay.qq.com',path:'/',hostOnly:false,secure:true});
      rows = rows.filter(function(r) { return !(r.name === name && r.domain === 'pay.qq.com' && r.path === '/'); });
      rows.push(copy);
    });
    return rows;
  }

  function isScpJump(u) { return u.host === 'scp.qq.com' && u.path === '/payr/jump.html'; }
  function isXinyueDirect(u) { return u.host === 'xinyue.qq.com' || /\.xinyue\.qq\.com$/.test(u.host); }

  function build(config, text, saved) {
    if (!config || (config.type !== '充值官网' && config.type !== '心悦')) fail('充值页面类型不正确。');
    var platform = config.browserPlatform || 'ios';
    if (platform !== 'ios' && platform !== 'android') fail('请选择安卓或苹果。');
    var userAgent = platform === 'android'
      ? 'Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Mobile Safari/537.36'
      : 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1';

    var recordMode = config.purpose === 'records';
    var parsed = extractCredentialParams(text);
    var baseUrl = recordMode
      ? 'https://pay.qq.com/h5/trade-record/trade-record.php?appid=1450000186&_wv=1024&pf=__mds_wx_qb&sessionid=hy_gameid'
      : config.url;
    var base = splitURL(baseUrl);
    var scp = !recordMode && isScpJump(base);
    var xinyueDirect = !recordMode && isXinyueDirect(base);
    var xinyueFlow = scp || xinyueDirect;

    // Normal rebate links merge CK immediately. SCP and direct xinyue.qq.com entry links
    // must first preserve Tencent/Xinyue's own entry URL and establish Xinyue-domain
    // login state in the same WebView session. If that flow later reaches pagedoo, CK is
    // merged into the final pagedoo URL there (same rule used by the proven WC TG flow).
    var finalUrl = xinyueFlow ? baseUrl.trim() : mergeIntoURL(baseUrl, parsed);
    var rows = cookieRows(saved, config.payerQQ, !!config.reusePayer), beforeWarmup = rows.slice(), warmupURL = '';

    if (xinyueFlow) {
      var extra = [
        ['appid','wx5a3bbeac0d87c75a'],
        ['access_token',parsed.openkey],
        ['openid',parsed.openid],
        ['eas_entry','https%3A%2F%2Fopen.weixin.qq.com%2F'],
        ['acctype','wx']
      ];
      extra.forEach(function (p) { beforeWarmup.push({name:p[0],value:p[1],domain:'xinyue.qq.com',path:'/',hostOnly:true}); });
      warmupURL = 'https://xinyue.qq.com/';
    }

    return {
      url:finalUrl,
      cookies:rows,
      sourceCookies:saved,
      payerQQ:String(config.payerQQ),
      ckParams:parsed.map,
      deferCkInjection:xinyueFlow,
      userAgent:userAgent,
      browserLabel:platform === 'android' ? '安卓' : '苹果',
      warmupURL:warmupURL,
      beforeWarmup:beforeWarmup
    };
  }

  root.SCLoginContext = {build:build, credentials:extractCredentialParams, mergeIntoURL:mergeIntoURL};
  if (typeof module !== 'undefined' && module.exports) module.exports = root.SCLoginContext;
})(typeof globalThis !== 'undefined' ? globalThis : this);
