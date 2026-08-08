# NetworkTools Dev Environment

This environment doesn't build its own image — it's a thin passthrough to
[`nicolaka/netshoot`](https://github.com/nicolaka/netshoot), the de facto
standard Docker network-troubleshooting image. Selecting it in
`devmenu.sh`/`devmenu.ps1` pulls `nicolaka/netshoot:latest` directly; there's
no "build locally" option and `requirements.local.txt` customization doesn't
apply here.

netshoot bundles (among others): `iproute2`, `iputils`, `dig`/`drill`,
`curl`, `nmap`, `tcpdump`, `tshark`, `mtr`, `iperf3`, `socat`, `ngrep`,
`conntrack`, and `ss`. See the
[netshoot README](https://github.com/nicolaka/netshoot#readme) for the full
list and usage notes.
