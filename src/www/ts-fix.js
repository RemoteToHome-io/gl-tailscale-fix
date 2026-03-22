/**
 * gl-tailscale-fix: Tailscale enhancements for GL.iNet routers
 * Copyright (c) 2026 RemoteToHome Consulting (https://remotetohome.io)
 * https://github.com/RemoteToHome-io/gl-tailscale-fix
 */
(function() {
'use strict';

var ROUTE = '#/tailscaleview';
var INJECT_ID = 'ts-fix-section';
var POLL_MS = 2000;
var VERSION = '{{VERSION}}';

// -- RPC helper --

function rpc(module, method, params) {
  var token = (document.cookie.match(/Admin-Token=([^;]+)/) || [])[1] || '';
  return fetch('/rpc', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({
      jsonrpc: '2.0', id: Date.now(),
      method: 'call',
      params: [token, module, method, params || {}]
    })
  }).then(function(r) { return r.json(); })
    .then(function(d) {
      if (d.error) throw new Error(d.error.message || 'RPC error');
      return d.result || {};
    });
}

// -- Version comparison (semantic) --

function versionCompare(a, b) {
  var pa = a.split('.').map(Number);
  var pb = b.split('.').map(Number);
  for (var i = 0; i < Math.max(pa.length, pb.length); i++) {
    var na = pa[i] || 0;
    var nb = pb[i] || 0;
    if (na > nb) return 1;
    if (na < nb) return -1;
  }
  return 0;
}

// -- CSS injection (once) --

function injectStyles() {
  if (document.getElementById('ts-fix-styles')) return;
  var style = document.createElement('style');
  style.id = 'ts-fix-styles';
  style.textContent = [
    '.ts-fix-divider {',
    '  padding: 12px 15px 6px;',
    '  font-size: 13px;',
    '  font-weight: 600;',
    '  color: #5272f7;',
    '  border-top: 2px solid #5272f7;',
    '  margin-top: 4px;',
    '  display: flex;',
    '  align-items: center;',
    '  justify-content: space-between;',
    '}',
    '.ts-fix-divider .ts-fix-badge {',
    '  font-size: 11px;',
    '  font-weight: 400;',
    '  color: #a0a0a3;',
    '}',
    '.ts-fix-row {',
    '  display: flex;',
    '  justify-content: space-between;',
    '  align-items: center;',
    '  padding: 14px 15px;',
    '  border-bottom: 1px solid #ebebf0;',
    '  min-height: 50px;',
    '  font-size: 14px;',
    '  color: #303133;',
    '}',
    '.ts-fix-hidden { display: none; }',
    '.ts-fix-label {',
    '  display: flex;',
    '  align-items: center;',
    '  gap: 6px;',
    '}',
    '.ts-fix-info {',
    '  display: inline-flex;',
    '  align-items: center;',
    '  justify-content: center;',
    '  width: 16px; height: 16px;',
    '  border-radius: 50%;',
    '  background: #e8e8ed;',
    '  color: #606266;',
    '  font-size: 11px;',
    '  font-weight: 700;',
    '  cursor: help;',
    '  position: relative;',
    '  flex-shrink: 0;',
    '}',
    '#ts-fix-tooltip {',
    '  position: fixed;',
    '  background: #333;',
    '  color: #fff;',
    '  padding: 8px 12px;',
    '  border-radius: 6px;',
    '  font-size: 12px;',
    '  font-weight: 400;',
    '  width: 280px;',
    '  white-space: normal;',
    '  z-index: 9999;',
    '  pointer-events: none;',
    '  line-height: 1.4;',
    '  display: none;',
    '}',
    '.ts-fix-toggle {',
    '  position: relative;',
    '  display: inline-block;',
    '  width: 36px; height: 22px;',
    '  border-radius: 11px;',
    '  background: #a0a0a3;',
    '  cursor: pointer;',
    '  transition: background 0.2s;',
    '  flex-shrink: 0;',
    '}',
    '.ts-fix-toggle.is-on { background: #00c8b5; }',
    '.ts-fix-toggle.is-disabled {',
    '  opacity: 0.5;',
    '  cursor: not-allowed;',
    '}',
    '.ts-fix-toggle::after {',
    '  content: "";',
    '  position: absolute;',
    '  width: 18px; height: 18px;',
    '  border-radius: 50%;',
    '  background: #fff;',
    '  top: 2px; left: 2px;',
    '  transition: transform 0.2s;',
    '}',
    '.ts-fix-toggle.is-on::after { transform: translateX(14px); }',
    '.ts-fix-value {',
    '  font-size: 14px;',
    '  color: #303133;',
    '  display: flex;',
    '  align-items: center;',
    '  gap: 10px;',
    '}',
    '.ts-fix-update-btn {',
    '  padding: 4px 14px;',
    '  border-radius: 14px;',
    '  border: 1px solid #5272f7;',
    '  background: transparent;',
    '  color: #5272f7;',
    '  font-size: 12px;',
    '  cursor: pointer;',
    '  transition: background 0.15s, color 0.15s;',
    '}',
    '.ts-fix-update-btn:hover {',
    '  background: #5272f7;',
    '  color: #fff;',
    '}',
    '.ts-fix-update-btn:disabled {',
    '  opacity: 0.5;',
    '  cursor: not-allowed;',
    '}',
    '.ts-fix-restore-btn {',
    '  padding: 4px 14px;',
    '  border-radius: 14px;',
    '  border: 1px solid #a0a0a3;',
    '  background: transparent;',
    '  color: #606266;',
    '  font-size: 12px;',
    '  cursor: pointer;',
    '}',
    '.ts-fix-restore-btn:hover {',
    '  background: #a0a0a3;',
    '  color: #fff;',
    '}',
    '.ts-fix-footer {',
    '  padding: 10px 15px;',
    '  font-size: 11px;',
    '  color: #a0a0a3;',
    '  text-align: center;',
    '}',
    '.ts-fix-footer a {',
    '  color: #5272f7;',
    '  text-decoration: none;',
    '}',
    '.ts-fix-footer a:hover { text-decoration: underline; }',
    '.ts-fix-status {',
    '  font-size: 12px;',
    '  color: #a0a0a3;',
    '  margin-left: 8px;',
    '}',
    '.ts-fix-status.is-ok { color: #00c8b5; }',
    '.ts-fix-status.is-err { color: #f56c6c; }',
    '',
    '/* Dark mode overrides (GL stores theme in localStorage) */',
    '.ts-fix-dark .ts-fix-row { color: #9195aa; border-bottom-color: rgba(145, 149, 170, 0.15); }',
    '.ts-fix-dark .ts-fix-value { color: #b9b9bd; }',
    '.ts-fix-dark .ts-fix-info { background: rgba(145, 149, 170, 0.25); color: #9195aa; }',
    '.ts-fix-dark .ts-fix-restore-btn { color: #9195aa; border-color: #606266; }',
    '.ts-fix-dark .ts-fix-restore-btn:hover { background: #606266; color: #fff; }',
    '.ts-fix-dark .ts-fix-footer { color: #606266; }',
    '.ts-fix-dark .ts-fix-badge { color: #606266; }',
    '.ts-fix-dark .ts-fix-status { color: #606266; }',
    '',
    '/* Refresh button */',
    '.ts-fix-refresh-btn {',
    '  display: inline-flex; align-items: center; justify-content: center;',
    '  width: 18px; height: 18px; border: none; background: transparent;',
    '  color: #a0a0a3; cursor: pointer; padding: 0; margin-left: 6px;',
    '  font-size: 14px; line-height: 1; vertical-align: middle;',
    '  transition: color 0.15s;',
    '}',
    '.ts-fix-refresh-btn:hover { color: #5272f7; }',
    '.ts-fix-refresh-btn.is-spinning { animation: ts-fix-spin 0.8s linear infinite; }',
    '@keyframes ts-fix-spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }',
    '.ts-fix-dark .ts-fix-refresh-btn { color: #606266; }',
    '.ts-fix-dark .ts-fix-refresh-btn:hover { color: #5272f7; }',
  ].join('\n');
  document.head.appendChild(style);
}

// -- Tooltip (JS-based, escapes overflow:hidden parents) --

var tipEl = null;

function initTooltip() {
  if (tipEl) return;
  tipEl = document.createElement('div');
  tipEl.id = 'ts-fix-tooltip';
  document.body.appendChild(tipEl);

  document.addEventListener('mouseover', function(e) {
    var info = e.target.closest('.ts-fix-info');
    if (!info) return;
    var text = info.getAttribute('data-tip');
    if (!text) return;
    tipEl.textContent = text;
    tipEl.style.display = 'block';
    var rect = info.getBoundingClientRect();
    var tipW = 280;
    var left = rect.right - tipW;
    var card = document.querySelector('.tailscale-wrapper') || document.querySelector('.gl-card');
    var minLeft = card ? card.getBoundingClientRect().left : 8;
    if (left < minLeft) left = minLeft;
    tipEl.style.left = left + 'px';
    tipEl.style.top = (rect.top - tipEl.offsetHeight - 6) + 'px';
  });

  document.addEventListener('mouseout', function(e) {
    var info = e.target.closest('.ts-fix-info');
    if (info) tipEl.style.display = 'none';
  });
}

// -- Tooltip text --

var TIPS = {
  exitNode: 'Advertise this router as a Tailscale exit node so remote devices can route all traffic through it. Requires "Allow Remote Access WAN" to be enabled above.',
  killSwitch: 'Routing-level kill switch - Uses policy routing to block all LAN/Guest traffic from reaching the WAN directly when Custom Exit Node routing is active and the tunnel connection is interrupted (e.g. an exit node drop). Persists even if tailscaled crashes or fails to start.',
  routeGuest: 'Extends GL\'s "Allow Remote Access" to the Guest network. Adds Guest\u2194Tailscale forwardings and advertises the guest subnet to your tailnet.',
  tailscaleSsh: 'Run a Tailscale SSH server on this router, allowing passwordless SSH from Tailscale peers. Requires an SSH ACL rule in the Tailscale admin console (Access Controls \u2192 Tailscale SSH tab). Note: this takes over port 22 for Tailscale traffic \u2014 LAN clients using subnet routing cannot use it. For access from both Tailscale peers and LAN clients, consider adding an alternate SSH port (e.g. 2222) in System \u2192 Administration \u2192 SSH Access instead.',
  version: 'Manage Tailscale binary version. Combined binaries provided by admonstrator/glinet-tailscale-updater.'
};

// -- Build UI --

function createToggleRow(id, label, tip, opts) {
  opts = opts || {};
  var row = document.createElement('div');
  row.className = 'ts-fix-row' + (opts.hidden ? ' ts-fix-hidden' : '');
  row.id = 'ts-fix-row-' + id;

  var labelDiv = document.createElement('div');
  labelDiv.className = 'ts-fix-label';
  labelDiv.textContent = label + ' ';

  var info = document.createElement('span');
  info.className = 'ts-fix-info';
  info.textContent = 'i';
  info.setAttribute('data-tip', tip);
  labelDiv.appendChild(info);

  var toggle = document.createElement('div');
  toggle.className = 'ts-fix-toggle';
  toggle.id = 'ts-fix-toggle-' + id;
  toggle.setAttribute('role', 'switch');
  toggle.setAttribute('aria-checked', 'false');

  row.appendChild(labelDiv);
  row.appendChild(toggle);
  return row;
}

function buildSection() {
  var section = document.createElement('div');
  section.id = INJECT_ID;

  // Divider
  var divider = document.createElement('div');
  divider.className = 'ts-fix-divider';
  var divLabel = document.createElement('span');
  divLabel.textContent = 'Tailscale Enhanced';
  divider.appendChild(divLabel);
  var badgeWrap = document.createElement('span');
  badgeWrap.style.cssText = 'display:inline-flex;align-items:center;';
  var badge = document.createElement('span');
  badge.className = 'ts-fix-badge';
  badge.textContent = 'gl-tailscale-fix v' + VERSION;
  badgeWrap.appendChild(badge);
  var refreshBtn = document.createElement('button');
  refreshBtn.className = 'ts-fix-refresh-btn';
  refreshBtn.title = 'Check for updates';
  refreshBtn.innerHTML = '&#x21bb;';
  refreshBtn.onclick = doRefreshVersions;
  badgeWrap.appendChild(refreshBtn);
  divider.appendChild(badgeWrap);
  section.appendChild(divider);

  // Allow Remote Access Guest (extends native GL function)
  section.appendChild(createToggleRow('route-guest', 'Allow Remote Access Guest', TIPS.routeGuest));

  // Kill Switch (extends native Custom Exit Node — shown when exit node client mode is active)
  section.appendChild(createToggleRow('kill-switch', 'Kill Switch', TIPS.killSwitch, {hidden: true}));

  // Advertise as Exit Node (new server-side functionality)
  section.appendChild(createToggleRow('exit-node', 'Advertise as Exit Node', TIPS.exitNode));
  section.appendChild(createToggleRow('tailscale-ssh', 'Enable Tailscale SSH', TIPS.tailscaleSsh));

  // WAN warning (shown when exit node ON but Allow Remote Access WAN is OFF)
  var wanWarn = document.createElement('div');
  wanWarn.id = 'ts-fix-wan-warn';
  wanWarn.className = 'ts-fix-hidden';
  wanWarn.style.cssText = 'color:#e6a23c;font-size:12px;padding:0 15px 10px;';
  wanWarn.textContent = '\u26a0 Enable "Allow Remote Access WAN" above and click Apply for exit node traffic to flow.';
  section.appendChild(wanWarn);

  // Version info row
  var verRow = document.createElement('div');
  verRow.className = 'ts-fix-row';
  verRow.id = 'ts-fix-row-version';

  var verLabel = document.createElement('div');
  verLabel.className = 'ts-fix-label';
  verLabel.textContent = 'Tailscale Version ';
  var verInfo = document.createElement('span');
  verInfo.className = 'ts-fix-info';
  verInfo.textContent = 'i';
  verInfo.setAttribute('data-tip', TIPS.version);
  verLabel.appendChild(verInfo);

  var verValue = document.createElement('div');
  verValue.className = 'ts-fix-value';
  verValue.id = 'ts-fix-version-info';
  verValue.textContent = 'Loading...';

  verRow.appendChild(verLabel);
  verRow.appendChild(verValue);
  section.appendChild(verRow);

  // Footer
  var footer = document.createElement('div');
  footer.className = 'ts-fix-footer';
  footer.innerHTML = 'Enhanced by <a href="https://remotetohome.io/gl-tailscale-fix" target="_blank" rel="noopener">gl-tailscale-fix</a> from <a href="https://remotetohome.io" target="_blank" rel="noopener">remotetohome.io</a>'
    + '<br>Tailscale binaries provided by <a href="https://github.com/Admonstrator/glinet-tailscale-updater" target="_blank" rel="noopener">glinet-tailscale-updater</a>';
  section.appendChild(footer);

  return section;
}

// -- State management --

var state = {
  advertise_exit_node: false,
  kill_switch: false,
  route_guest: false,
  tailscale_ssh: false,
  ts_enabled: false,
  ts_running: false,
  wan_enabled: false,
  ts_version: 'unknown',
  exit_node_ip: '',
  exit_node_active: false,
  ssh_active: false,
  kill_switch_fw_active: false,
  route_guest_fw_active: false
};

var updateState = {};
var pluginState = {};
var pendingChanges = {};

function setToggle(id, on, disabled) {
  var el = document.getElementById('ts-fix-toggle-' + id);
  if (!el) return;
  if (on) {
    el.classList.add('is-on');
  } else {
    el.classList.remove('is-on');
  }
  if (disabled) {
    el.classList.add('is-disabled');
  } else {
    el.classList.remove('is-disabled');
  }
  el.setAttribute('aria-checked', on ? 'true' : 'false');
}

function showRow(id, visible) {
  var row = document.getElementById('ts-fix-row-' + id);
  if (!row) return;
  if (visible) {
    row.classList.remove('ts-fix-hidden');
  } else {
    row.classList.add('ts-fix-hidden');
  }
}

function isGlExitNodeEnabled() {
  // Detect GL's Custom Exit Node toggle state from the DOM (before Apply)
  var items = document.querySelectorAll('ul.tailscale-config li');
  for (var i = 0; i < items.length; i++) {
    if (items[i].textContent.indexOf('Custom Exit Node') !== -1) {
      var sw = items[i].querySelector('.gl-switch');
      return sw && sw.classList.contains('is-checked');
    }
  }
  return false;
}

function refreshUI() {
  var notReady = !state.ts_enabled || !state.ts_running;

  // Hide toggle rows entirely when Tailscale is disabled
  showRow('exit-node', state.ts_enabled);
  showRow('route-guest', state.ts_enabled);
  showRow('tailscale-ssh', state.ts_enabled);
  // Show kill switch when exit node is configured (backend) OR toggled on in GL UI (pre-Apply)
  showRow('kill-switch', state.ts_enabled && (state.exit_node_ip !== '' || isGlExitNodeEnabled()));

  // Show "enable Tailscale" hint when disabled
  var hint = document.getElementById('ts-fix-disabled-hint');
  if (!state.ts_enabled) {
    if (!hint) {
      hint = document.createElement('div');
      hint.id = 'ts-fix-disabled-hint';
      hint.className = 'ts-fix-row';
      hint.style.cssText = 'color:#a0a0a3;font-size:13px;justify-content:center;';
      hint.textContent = 'Enable Tailscale above to configure these settings.';
      var section = document.getElementById(INJECT_ID);
      var divider = section && section.querySelector('.ts-fix-divider');
      if (divider && divider.nextSibling) {
        section.insertBefore(hint, divider.nextSibling);
      }
    }
    hint.style.display = '';
  } else if (hint) {
    hint.style.display = 'none';
  }

  setToggle('exit-node', state.advertise_exit_node, notReady);
  setToggle('route-guest', state.route_guest, notReady);
  setToggle('tailscale-ssh', state.tailscale_ssh, notReady);
  setToggle('kill-switch', state.kill_switch, notReady);

  // WAN warning: show when exit node enabled but Allow Remote Access WAN is off
  var wanWarn = document.getElementById('ts-fix-wan-warn');
  if (wanWarn) {
    if (state.advertise_exit_node && !state.wan_enabled) {
      wanWarn.classList.remove('ts-fix-hidden');
    } else {
      wanWarn.classList.add('ts-fix-hidden');
    }
  }

  // Keep Apply button active while we have pending changes
  if (Object.keys(pendingChanges).length > 0) {
    activateApplyButton();
  }

  // Version info
  var verEl = document.getElementById('ts-fix-version-info');
  if (verEl) {
    verEl.innerHTML = '';
    var verText = document.createTextNode(state.ts_version || 'unknown');
    verEl.appendChild(verText);

    if (updateState.latest_version && updateState.latest_version !== 'checking...'
        && updateState.update_available) {
      var arrow = document.createTextNode(' \u2192 ' + updateState.latest_version + ' ');
      verEl.appendChild(arrow);

      var btn = document.createElement('button');
      btn.className = 'ts-fix-update-btn';
      btn.textContent = 'Update';
      btn.id = 'ts-fix-update-btn';
      btn.onclick = doUpdate;
      verEl.appendChild(btn);
    } else if (updateState.latest_version === 'checking...') {
      var checking = document.createElement('span');
      checking.className = 'ts-fix-status';
      checking.textContent = 'checking for updates...';
      verEl.appendChild(checking);
    } else if (updateState.latest_version && !updateState.update_available
               && updateState.latest_version !== 'checking...') {
      var upToDate = document.createElement('span');
      upToDate.className = 'ts-fix-status is-ok';
      upToDate.textContent = '(latest)';
      verEl.appendChild(upToDate);
    }

    // Restore button (always available)
    var restoreBtn = document.createElement('button');
    restoreBtn.className = 'ts-fix-restore-btn';
    restoreBtn.textContent = 'Restore';
    restoreBtn.title = 'Restore factory Tailscale binaries from /rom/';
    restoreBtn.onclick = doRestore;
    verEl.appendChild(document.createTextNode(' '));
    verEl.appendChild(restoreBtn);
  }
}

// -- Data fetching --

function fetchConfig() {
  rpc('ts-fix', 'get_config', {}).then(function(res) {
    if (res.err_code) return;
    Object.keys(res).forEach(function(k) {
      // Don't overwrite keys with pending (unstaged) changes
      if (!(k in pendingChanges)) {
        state[k] = res[k];
      }
    });
    refreshUI();
  }).catch(function() {});
}

function fetchUpdateInfo() {
  rpc('ts-fix', 'get_update_info', {}).then(function(res) {
    if (res.err_code) return;
    updateState = res;
    state.ts_version = res.installed_version || state.ts_version;
    refreshUI();

    // If still checking, poll again
    if (res.latest_version === 'checking...') {
      setTimeout(fetchUpdateInfo, 3000);
    }
  }).catch(function() {});
}

function fetchPluginInfo() {
  rpc('ts-fix', 'get_plugin_info', {}).then(function(res) {
    pluginState = res;
    refreshPluginBadge();

    if (res.latest_version === 'checking...') {
      setTimeout(fetchPluginInfo, 3000);
    }
  }).catch(function() {});
}

function refreshPluginBadge() {
  var badge = document.querySelector('.ts-fix-badge');
  if (!badge) return;

  var text = 'gl-tailscale-fix v' + VERSION;

  if (pluginState.latest_version && pluginState.latest_version !== 'checking...'
      && pluginState.latest_version !== 'unavailable'
      && versionCompare(pluginState.latest_version, VERSION) > 0) {
    badge.innerHTML = '';
    badge.appendChild(document.createTextNode(text + ' \u2014 '));

    var link = document.createElement('a');
    link.href = pluginState.release_url || 'https://github.com/RemoteToHome-io/gl-tailscale-fix/releases';
    link.target = '_blank';
    link.rel = 'noopener';
    link.style.cssText = 'color:#e6a23c;text-decoration:none;font-weight:600;';
    link.textContent = 'v' + pluginState.latest_version + ' available';
    badge.appendChild(link);
  } else {
    badge.textContent = text;
  }
}

// -- Actions --

function toggleSetting(key) {
  var newVal = !state[key];
  state[key] = newVal;
  pendingChanges[key] = newVal;
  refreshUI();
  activateApplyButton();
}

function activateApplyButton() {
  var wrapper = document.querySelector('.tailscale-wrapper');
  if (!wrapper) return;
  var buttons = wrapper.querySelectorAll('button');
  for (var i = 0; i < buttons.length; i++) {
    var btn = buttons[i];
    if (btn.textContent.trim() === 'Apply' && btn.__vue__) {
      btn.__vue__.disabled = false;
      break;
    }
  }
}

function applyPendingChanges() {
  var keys = Object.keys(pendingChanges);
  if (keys.length === 0) return;

  var params = {};
  keys.forEach(function(k) { params[k] = pendingChanges[k]; });
  pendingChanges = {};

  rpc('ts-fix', 'set_config', params).then(function(res) {
    if (res.err_code) {
      // Revert on error
      keys.forEach(function(k) { state[k] = !params[k]; });
      refreshUI();
      return;
    }
    setTimeout(fetchConfig, 500);
  }).catch(function() {
    keys.forEach(function(k) { state[k] = !params[k]; });
    refreshUI();
  });
}

function doUpdate() {
  var btn = document.getElementById('ts-fix-update-btn');
  if (btn) {
    btn.disabled = true;
    btn.textContent = 'Updating...';
  }

  rpc('ts-fix', 'do_update', {}).then(function(res) {
    if (res.err_code) {
      if (btn) { btn.textContent = 'Error'; btn.disabled = false; }
      return;
    }
    // Poll for update status
    pollUpdateStatus();
  }).catch(function() {
    if (btn) { btn.textContent = 'Error'; btn.disabled = false; }
  });
}

function pollUpdateStatus() {
  rpc('ts-fix', 'get_update_status', {}).then(function(res) {
    var btn = document.getElementById('ts-fix-update-btn');
    if (res.status === 'running') {
      if (btn) btn.textContent = res.message || 'Updating...';
      setTimeout(pollUpdateStatus, POLL_MS);
    } else if (res.status === 'success') {
      if (btn) { btn.textContent = 'Done!'; btn.disabled = true; }
      setTimeout(function() { fetchConfig(); fetchUpdateInfo(); }, 1000);
    } else if (res.status === 'error') {
      if (btn) { btn.textContent = 'Failed'; btn.disabled = false; }
    } else {
      // idle — update may have completed before we started polling
      setTimeout(function() { fetchConfig(); fetchUpdateInfo(); }, 1000);
    }
  }).catch(function() {
    if (window.location.hash.indexOf(ROUTE) === 0) {
      setTimeout(pollUpdateStatus, POLL_MS);
    }
  });
}

function doRestore() {
  if (!confirm('Restore factory Tailscale binaries? The router will use the version that shipped with the firmware.')) return;

  rpc('ts-fix', 'do_restore', {}).then(function(res) {
    if (res.err_code) {
      alert('Restore failed: ' + (res.err_msg || 'unknown error'));
      return;
    }
    // Poll for completion
    pollUpdateStatus();
  }).catch(function(e) {
    alert('Restore failed: ' + e.message);
  });
}

function doRefreshVersions() {
  var btn = document.querySelector('.ts-fix-refresh-btn');
  if (!btn || btn.classList.contains('is-spinning')) return;
  btn.classList.add('is-spinning');
  rpc('ts-fix', 'force_check_versions', {}).then(function() {
    fetchUpdateInfo();
    fetchPluginInfo();
    setTimeout(function() {
      var b = document.querySelector('.ts-fix-refresh-btn');
      if (b) b.classList.remove('is-spinning');
    }, 1500);
  }).catch(function() {
    var b = document.querySelector('.ts-fix-refresh-btn');
    if (b) b.classList.remove('is-spinning');
  });
}

// -- GL Apply button interception --
// GL's Apply calls "gl_tailscale restart" which runs "tailscale up --reset",
// clearing our exit node and other settings. After GL's restart completes,
// we re-apply our settings via set_config.

var applyHooked = false;

function reapplyAfterGlRestart() {
  // GL's "gl_tailscale restart" flow: stop → start → tailscale up --reset.
  // The daemon reaches Running state BEFORE "tailscale up --reset" clears our
  // settings. We must wait for gl_tailscale to fully exit, not just for Running.
  var attempts = 0;
  var maxAttempts = 40; // ~80 seconds
  var sawNotRunning = false;

  function poll() {
    if (attempts >= maxAttempts) return;
    attempts++;

    rpc('ts-fix', 'get_config', {}).then(function(res) {
      if (res.err_code) { setTimeout(poll, 2000); return; }

      // Phase 1: wait for tailscale to go down (confirms restart began)
      if (!res.ts_running) {
        sawNotRunning = true;
        setTimeout(poll, 2000);
        return;
      }

      // Phase 2: tailscale is running, but gl_tailscale restart may still
      // be executing "tailscale up --reset". Wait an extra cycle to let it
      // finish, then re-apply. If we never saw it go down (fast restart),
      // still wait extra to be safe.
      if (!sawNotRunning && attempts < 5) {
        setTimeout(poll, 2000);
        return;
      }

      // Phase 3: re-apply our settings
      doReapply();
    }).catch(function() { setTimeout(poll, 2000); });
  }

  function doReapply() {
    var params = {};
    var needReapply = false;

    // Only reapply tailscale-level settings that "tailscale up --reset" clears.
    // Kill switch uses kernel ip rules/routes which survive the restart — no
    // reapply needed. Reapplying KS here would race with ts-fix-reapply's
    // auto-disable (exit_node_ip empty → kill_switch=0) and overwrite it.
    if (state.advertise_exit_node) {
      params.advertise_exit_node = true;
      needReapply = true;
    }
    if (state.route_guest) {
      params.route_guest = true;
      needReapply = true;
    }
    if (state.tailscale_ssh) {
      params.tailscale_ssh = true;
      needReapply = true;
    }

    if (needReapply) {
      rpc('ts-fix', 'set_config', params).then(function() {
        // Verify after 5s that settings actually took effect
        setTimeout(verifyReapply, 5000);
      });
    } else {
      setTimeout(fetchConfig, 500);
    }
  }

  function verifyReapply() {
    rpc('ts-fix', 'get_config', {}).then(function(res) {
      if (res.err_code || !res.ts_running) {
        setTimeout(fetchConfig, 1000);
        return;
      }

      // Check if exit node was cleared by a late "tailscale up --reset"
      var needFix = false;
      var fixParams = {};

      if (state.advertise_exit_node && !res.exit_node_active) {
        fixParams.advertise_exit_node = true;
        needFix = true;
      }
      if (state.route_guest && !res.route_guest_fw_active) {
        fixParams.route_guest = true;
        needFix = true;
      }
      if (state.tailscale_ssh && !res.ssh_active) {
        fixParams.tailscale_ssh = true;
        needFix = true;
      }

      if (needFix) {
        rpc('ts-fix', 'set_config', fixParams).then(function() {
          setTimeout(fetchConfig, 1000);
        });
      } else {
        fetchConfig();
      }
    }).catch(function() { setTimeout(fetchConfig, 1000); });
  }

  // Delay before first poll — give GL's restart time to begin
  setTimeout(poll, 3000);
}

function hookApplyButton() {
  if (applyHooked) return;

  // Use event delegation on document.body instead of binding to the button
  // directly. GL's Vue re-renders destroy and recreate the Apply button,
  // losing any directly-attached event listeners. Delegation survives.
  document.body.addEventListener('click', function(e) {
    if (window.location.hash.indexOf(ROUTE) !== 0) return;

    // Walk up from click target to find an Apply button
    var btn = e.target.closest ? e.target.closest('button') : null;
    if (!btn) {
      // Fallback for older browsers without closest()
      var el = e.target;
      while (el && el.tagName !== 'BUTTON') el = el.parentElement;
      btn = el;
    }
    if (!btn || btn.textContent.trim() !== 'Apply') return;

    // Only act when inside the tailscale page wrapper
    var wrapper = btn.closest('.tailscale-wrapper') || btn.closest('.gl-card');
    if (!wrapper) return;

    // Apply our staged changes
    applyPendingChanges();
    // GL's Apply triggers gl_tailscale restart in the background
    reapplyAfterGlRestart();
  });
  applyHooked = true;
}

// -- DOM injection --

function inject() {
  if (document.getElementById(INJECT_ID)) return;
  if (window.location.hash.indexOf(ROUTE) !== 0) return;

  var configList = document.querySelector('ul.tailscale-config');
  if (!configList) return;

  injectStyles();
  initTooltip();

  var section = buildSection();

  // Apply dark mode class if GL's theme is dark
  if (localStorage.getItem('theme') === 'dark') {
    section.classList.add('ts-fix-dark');
  }

  // Insert after the config list
  configList.parentNode.insertBefore(section, configList.nextSibling);

  // Re-evaluate our row visibility when user clicks GL's config toggles
  // (e.g., Custom Exit Node toggle changes kill switch row visibility)
  configList.addEventListener('click', function() {
    setTimeout(refreshUI, 150);
  });

  // Wire up toggle clicks
  var toggles = {
    'exit-node': 'advertise_exit_node',
    'route-guest': 'route_guest',
    'tailscale-ssh': 'tailscale_ssh',
    'kill-switch': 'kill_switch'
  };

  Object.keys(toggles).forEach(function(id) {
    var el = document.getElementById('ts-fix-toggle-' + id);
    if (el) {
      el.addEventListener('click', function() {
        if (el.classList.contains('is-disabled')) return;
        toggleSetting(toggles[id]);
      });
    }
  });

  // Hook GL's Apply button (event delegation — only needs to run once)
  hookApplyButton();

  // Initial data fetch
  fetchConfig();
  fetchUpdateInfo();
  fetchPluginInfo();
}

// -- Periodic config refresh (keeps UI in sync with backend) --

var refreshTimer = null;

function startRefreshTimer() {
  if (refreshTimer) return;
  refreshTimer = setInterval(function() {
    var section = document.getElementById(INJECT_ID);
    if (window.location.hash.indexOf(ROUTE) === 0 && section) {
      fetchConfig();
      // Sync dark mode (catches runtime theme toggle)
      var isDark = localStorage.getItem('theme') === 'dark';
      if (isDark && !section.classList.contains('ts-fix-dark')) {
        section.classList.add('ts-fix-dark');
      } else if (!isDark && section.classList.contains('ts-fix-dark')) {
        section.classList.remove('ts-fix-dark');
      }
    }
  }, 10000); // every 10s
}

function stopRefreshTimer() {
  if (refreshTimer) { clearInterval(refreshTimer); refreshTimer = null; }
}

// -- Route watching --

function onRouteChange() {
  if (window.location.hash.indexOf(ROUTE) === 0) {
    // Small delay to let Vue render the page first
    setTimeout(inject, 300);
    setTimeout(inject, 800);
    setTimeout(inject, 1500);
    startRefreshTimer();
  } else {
    stopRefreshTimer();
  }
}

// -- MutationObserver for Vue re-renders --

var observer = null;

function startObserver() {
  if (observer) return;

  observer = new MutationObserver(function() {
    if (window.location.hash.indexOf(ROUTE) === 0) {
      if (!document.getElementById(INJECT_ID) && document.querySelector('ul.tailscale-config')) {
        inject();
      }
    }
  });

  var target = document.getElementById('app') || document.body;
  observer.observe(target, {childList: true, subtree: true});
}

// -- Init --

window.addEventListener('hashchange', onRouteChange);
onRouteChange();
startObserver();

})();
