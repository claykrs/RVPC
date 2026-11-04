# Networking — NE2000 + virtual ISP

## Guest side
- NE2000-compatible ISA card at 0x300, IRQ10.
- 16 KiB ring buffer, page-based transmit/receive.
- Windows 98 has a built-in NE2000 driver; DOS uses a packet driver.

## Host side
Implement a small TCP/IP stack in Luau:

- ARP, IPv4, ICMP
- UDP, TCP (enough for HTTP/IRC/Telnet)
- DHCP server, DNS resolver
- virtual switch/bridge

## Virtual ISP
A Roblox-hosted network with:

- DHCP lease and DNS names
- HTTP server with retro pages
- IRC server
- BBS / mail / FTP
- multiplayer game lobby

No external dependency and no TLS problems.

## Real internet relay
For real HTTP/TCP, run a small relay outside Roblox:

- Roblox server <-> relay over HTTPS/long-poll (no WebSocket/raw TCP in
  `HttpService`).
- Relay opens real sockets and forwards bytes.
- TLS is terminated at the relay; the guest sees plain HTTP where needed.

Never expose Roblox cookies or raw credentials to guest code.
