#!/usr/bin/env python3
"""Real sockets in disposable netns, never a mocked routing decision."""
import socket, sys, threading, time
from pathlib import Path
HOST='223.5.5.5'
if sys.argv[1]=='server':
    ident=sys.argv[2].encode()
    HOST=sys.argv[3] if len(sys.argv)>3 else HOST
    def handle(conn):
        with conn:
            while conn.recv(1): conn.sendall(ident)
    def tcp():
        s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind((HOST,9001));s.listen(128)
        while True:
            conn,_=s.accept();threading.Thread(target=handle,args=(conn,),daemon=True).start()
    threading.Thread(target=tcp,daemon=True).start()
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind((HOST,9000))
    while True:
        _,addr=s.recvfrom(128);s.sendto(ident,addr)
elif sys.argv[1]=='connect':
    with socket.create_connection((sys.argv[2],int(sys.argv[3])),2) as s:
        s.sendall(b'x');assert s.recv(1).decode()==sys.argv[4]
elif sys.argv[1]=='sample':
    count,start=int(sys.argv[2]),int(sys.argv[3]); expected=float(sys.argv[4]);counts=[0,0]; retries=0
    for i in range(count):
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
            s.settimeout(2);s.bind(('0.0.0.0',start+i))
            # UDP initial delivery is not guaranteed. The host NAT control case
            # also has rare insert_failed races. Retry on this same socket, with
            # a strict bound; established flow pinning below permits no retry.
            for attempt in range(3):
                s.sendto(b'x',(HOST,9000))
                try:
                    ident=int(s.recv(8));break
                except TimeoutError:
                    retries+=1
                    if attempt==2: raise AssertionError(('UDP unavailable',start+i))
            assert retries <= max(3,count//1000), ('excessive initial UDP loss',retries)
            counts[ident]+=1
            # The same UDP connection must never be rescheduled.
            s.sendto(b'y',(HOST,9000));assert int(s.recv(8))==ident
    assert abs(counts[1]/count-expected)<0.03,(counts,expected)
    print('weighted sockets:',counts,'initial UDP retries:',retries,flush=True)
elif sys.argv[1]=='blocked':
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
        s.settimeout(.3);s.bind(('0.0.0.0',int(sys.argv[2])));s.sendto(b'blocked',(HOST,9000))
        try: s.recv(8)
        except (TimeoutError,ConnectionRefusedError): pass
        else: raise AssertionError('unhealthy fixed exit leaked')
elif sys.argv[1]=='pin':
    base=Path(sys.argv[2]); conns={}
    for _ in range(64):
        s=socket.create_connection((HOST,9001),2);s.sendall(b'x');ident=int(s.recv(1))
        if ident in conns:s.close()
        else:conns[ident]=s
        if len(conns)==2:break
    assert len(conns)==2
    (base/'ready').touch()
    for phase in range(1,4):
        deadline=time.monotonic()+40
        while not (base/f'phase{phase}').exists():
            assert time.monotonic()<deadline,'controller timed out';time.sleep(.05)
        for ident,s in conns.items():
            if phase==2 and ident==0:continue
            s.sendall(b'x');assert int(s.recv(1))==ident,'TCP exit changed'
        (base/f'done{phase}').touch()
    for s in conns.values():s.close()
