/// Moon server endpoint ID (z32 string form).
const String moonServerId = '6223e789d11fc77ebd301395498d7508194ba667ca139b5da1b4e5a49ff7cd55';

/// Moon server ALPN protocol identifier (original wave protocol).
const String moonRouterAlpn = 'dns-v1';

/// Client inbound ALPN for accepting direct DMs.
const String moonDmAlpn = 'moon-dm-v1';

/// Decoded from node_ticket — direct IP addresses only (no relay URLs).
const List<String> moonServerIpAddrs = [
  '[240e:348:9506:970:3fe4:eb28:ba5b:fa08]:47168',
  '[240e:348:9506:970:9563:16d1:1c0b:67e9]:47168',
  '[240e:348:9506:970:c23c:744e:fac8:a]:47168',
];

/// iroh n0 生产中继地址。所有客户端都绑定同一组 relay，这样通过 eid(nodeId)
/// 无需 Moon 服务器即可在线上打洞/中继连接对方。与 `presets::N0` 默认 relay 一致。
const List<String> defaultRelayUrls = [
  'https://use1-1.relay.n0.iroh.link/',
  'https://usw1-1.relay.n0.iroh.link/',
  'https://euc1-1.relay.n0.iroh.link/',
  'https://aps1-1.relay.n0.iroh.link/',
];
