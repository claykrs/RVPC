# Networking - NE2000 + virtual ISP

## Guest side

- `core/Ne2000.lua`: DP8390-compatible ISA card at `0x300`, IRQ10.
- 32 KiB packet RAM; pages `0x46..0x7F` form the receive ring, with 16-bit
  remote DMA through `0x310`.
- MAC/PAR page, receive/transmit status, interrupt mask/status, ring wrap and
  a host transmit callback.
- Windows 98 has a built-in NE2000 driver; DOS uses a packet driver.
- `tests/Ne2000Tests.lua` covers reset, PAR, remote DMA, TX, RX headers and IRQs.

## Host side

`core/Isp.lua` is the in-process virtual ISP. It is environment-pure and attaches
to a NE2000:

```lua
const isp = Isp.new()
isp:attach(ne2000)
```

Implemented now:

- Ethernet framing and ARP request/reply.
- IPv4 header/checksum and ICMP echo reply.
- UDP transport helper.
- DHCP DISCOVER/OFFER and REQUEST/ACK for `10.0.2.15`.
- DNS A answers (`rvpc.local` -> `10.0.2.80` by default).
- NE2000-to-ISP ARP round trip covered by a test.

Next network work:

- TCP state machine and a minimal HTTP server.
- IRC/BBS/mail services on the virtual ISP.
- Packet-driver and NDIS smoke tests once FreeDOS/Windows boots.

## Real internet relay

For real HTTP/TCP, run a small relay outside Roblox:

- Roblox server <-> relay over HTTPS/long-poll (no WebSocket/raw TCP in
  `HttpService`).
- Relay opens real sockets and forwards bytes.
- TLS is terminated at the relay; the guest sees plain HTTP where needed.

Never expose Roblox cookies or raw credentials to guest code.
