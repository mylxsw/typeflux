# IPv4 subnet calculator

Show CIDR, masks, network, broadcast, host range and address counts.

Requires Python 3. No network requests or package installation at runtime.

- `subnet 192.168.1.42/24` — Calculate an IPv4 CIDR subnet.
- `subnet 192.168.1.42 255.255.255.0` — Use a dotted-decimal mask; /31 and /32 are supported.

Text can be typed after the keyword or supplied from the current selection. Control arguments choose the operation; remaining text takes precedence over the selection. Results are shown for review and can be copied.

Supports CIDR and contiguous dotted masks. IPv4 only. Does not enumerate hosts, so /0 is safe. /31 provides two point-to-point hosts and /32 one host, neither with a broadcast address.
