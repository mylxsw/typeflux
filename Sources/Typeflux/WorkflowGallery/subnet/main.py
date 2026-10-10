#!/usr/bin/env python3
"""Calculate IPv4 CIDR or a dotted-decimal subnet mask locally."""
import ipaddress
import json
import sys

def calculate(text):
    parts=text.strip().split()
    if len(parts)==2:
        text=parts[0]+'/'+parts[1]
    elif len(parts)!=1 or '/' not in text:
        raise ValueError('Type: subnet 192.168.1.42/24 or subnet 192.168.1.42 255.255.255.0')
    interface=ipaddress.IPv4Interface(text)
    network=interface.network
    count=network.num_addresses if network.prefixlen>=31 else network.num_addresses-2
    first=network.network_address if network.prefixlen>=31 else network.network_address+1
    last=network.broadcast_address if network.prefixlen>=31 else network.broadcast_address-1
    rows=[('CIDR',str(network)),('IP',str(interface.ip)),('Subnet mask',str(network.netmask)),('Wildcard mask',str(network.hostmask)),('Network',str(network.network_address)),('Broadcast' if network.prefixlen<31 else 'Last address (no broadcast)',str(network.broadcast_address)),('First host',str(first)),('Last host',str(last)),('Usable hosts',str(count)),('Total addresses',str(network.num_addresses))]
    return json.dumps({'items':[{'uid':name,'title':value,'subtitle':name,'arg':value,'action':'copy'} for name,value in rows]})

if __name__=='__main__':
    try:
        request=json.loads(sys.stdin.readline() or '{}')
        print(calculate((sys.argv[1] if len(sys.argv)>1 else '') or request.get('selection') or ''))
    except ValueError as error:
        print(json.dumps({'error':str(error)})); sys.exit(1)
