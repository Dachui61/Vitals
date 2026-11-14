// t20_selsweep.c — exhaustive selector sweep on the AppleSMC endpoint (struct + legacy method)
#include <stdio.h>
#include <string.h>
#include <mach/mach.h>
#include <IOKit/IOKitLib.h>
static const char *err(kern_return_t kr){
  switch(kr){case kIOReturnSuccess:return "OK";
    case kIOReturnNotPrivileged:return "NotPrivileged";
    case kIOReturnNotPermitted:return "NotPermitted";
    case kIOReturnExclusiveAccess:return "ExclusiveAccess";
    case kIOReturnUnsupported:return "Unsupported";
    case kIOReturnBadArgument:return "BadArgument";
    case kIOReturnBusy:return "Busy";case kIOReturnError:return "Error";default:return "?";}
}
int main(void){
  CFMutableDictionaryRef m = IOServiceMatching("AppleSMC");
  io_iterator_t it; IOServiceGetMatchingServices(kIOMainPortDefault,m,&it);
  io_service_t svc = IOIteratorNext(it);
  io_connect_t conn=0;
  if(IOServiceOpen(svc,mach_task_self_,0,&conn)!=kIOReturnSuccess){printf("open failed\n");return 1;}
  unsigned char in[168], out[168];
  memset(in,0,sizeof in); memcpy(in,"Tp09",4); in[0x1c]=4; in[0x2a]=6; memcpy(in+0x30,"Tp09",4);
  printf("=== struct method, 168 in / 168 out ===\n");
  for(unsigned sel=0; sel<64; sel++){
    size_t outCnt=168; memset(out,0,sizeof out);
    kern_return_t kr=IOConnectCallStructMethod(conn,sel,in,168,out,&outCnt);
    printf("  sel %2u: %-14s outCnt=%zu\n",sel,err(kr),outCnt);
  }
  printf("=== legacy IOConnectCallMethod, 168 in / 168 out ===\n");
  for(unsigned sel=0; sel<16; sel++){
    uint64_t scalars[4]={0,0,0,0}; uint32_t scnt=4;
    size_t outCnt=168; memset(out,0,sizeof out); size_t outStructCnt=168;
    kern_return_t kr=IOConnectCallMethod(conn,sel,scalars,scnt,in,168,NULL,&scnt,out,&outStructCnt);
    printf("  sel %2u: %-14s outStructCnt=%zu\n",sel,err(kr),outStructCnt);
  }
  printf("=== scalar method, all NULL ===\n");
  for(unsigned sel=0; sel<16; sel++){
    kern_return_t kr=IOConnectCallScalarMethod(conn,sel,NULL,0,NULL,NULL);
    printf("  sel %2u: %s\n",sel,err(kr));
  }
  IOServiceClose(conn);
  return 0;
}
