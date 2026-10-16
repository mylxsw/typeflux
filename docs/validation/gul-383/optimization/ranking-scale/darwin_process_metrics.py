#!/usr/bin/env python3
"""Unprivileged numeric metrics for an explicitly owned PID; Darwin SDK rusage_info_v2 ABI."""
import ctypes, json, os, time

class Usage(ctypes.Structure):
    _fields_ = [('uuid',ctypes.c_uint8*16)] + [(name,ctypes.c_uint64) for name in [
        'user','system','package_wakeups','interrupt_wakeups','pageins','wired','resident','physical',
        'started','exited','child_user','child_system','child_package_wakeups','child_interrupt_wakeups',
        'child_pageins','child_elapsed','disk_read','disk_written']]

library = ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
library.proc_pid_rusage.argtypes = [ctypes.c_int,ctypes.c_int,ctypes.c_void_p]
library.proc_pid_rusage.restype = ctypes.c_int
class Timebase(ctypes.Structure):
    _fields_ = [('numerator',ctypes.c_uint32),('denominator',ctypes.c_uint32)]
system = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
system.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
timebase = Timebase()
assert system.mach_timebase_info(ctypes.byref(timebase)) == 0 and timebase.denominator > 0

def snapshot(pid):
    usage = Usage()
    if library.proc_pid_rusage(pid,2,ctypes.byref(usage)) != 0:
        return dict(available=False,error=ctypes.get_errno())
    return dict(available=True,cpu_user_ns=usage.user*timebase.numerator//timebase.denominator,
                cpu_system_ns=usage.system*timebase.numerator//timebase.denominator,
                cpu_user_absolute=usage.user,cpu_system_absolute=usage.system,
                timebase_numerator=timebase.numerator,timebase_denominator=timebase.denominator,
                physical_footprint_bytes=usage.physical,resident_bytes=usage.resident,
                disk_read_bytes=usage.disk_read,disk_written_bytes=usage.disk_written,
                pageins=usage.pageins,process_start_absolute=usage.started)

if __name__ == '__main__':
    before=snapshot(os.getpid());start=time.process_time_ns();deadline=time.monotonic()+.25
    while time.monotonic()<deadline: pass
    cpu=time.process_time_ns()-start;after=snapshot(os.getpid())
    measured=after['cpu_user_ns']+after['cpu_system_ns']-before['cpu_user_ns']-before['cpu_system_ns']
    assert ctypes.sizeof(Usage)==160
    assert abs(measured-cpu)<10_000_000,(measured,cpu)
    print(json.dumps(dict(abi_bytes=ctypes.sizeof(Usage),observed_cpu_ns=measured,
                         process_time_reference_ns=cpu,after=after,
                         scope='ABI and CPU-unit cross-check against this process only; no background resource claim.')))
