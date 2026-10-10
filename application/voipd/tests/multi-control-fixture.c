#include <libubus.h>
#include <libubox/blobmsg.h>
#include <libubox/uloop.h>
#include <string.h>
static struct ubus_object objects[2];
static int reply(struct ubus_context *bus,struct ubus_object *object,struct ubus_request_data *request,const char *method,struct blob_attr *message)
{
 struct blob_buf output={0};(void)method;(void)message;
 blob_buf_init(&output,0);blobmsg_add_string(&output,"status","ok");
 blobmsg_add_string(&output,"modem_id",object==&objects[0] ? "m1" : "m2");
 blobmsg_add_string(&output,"group",object==&objects[0] ? "first" : "second");
 ubus_send_reply(bus,request,output.head);blob_buf_free(&output);return 0;
}
static const struct ubus_method methods[]={UBUS_METHOD_NOARG("status",reply),UBUS_METHOD_NOARG("originate",reply)};
static struct ubus_object_type type=UBUS_OBJECT_TYPE("fixture",methods);
int main(void)
{
 struct ubus_context *bus;
 if(uloop_init() || !(bus=ubus_connect(NULL)))return 1;
 ubus_add_uloop(bus);
 for(int i=0;i<2;i++) {
  objects[i].name=i ? "qmodem.voip.second" : "qmodem.voip.first";
  objects[i].type=&type;objects[i].methods=methods;objects[i].n_methods=2;
  if(ubus_add_object(bus,&objects[i]))return 1;
 }
 uloop_run();ubus_free(bus);uloop_done();return 0;
}
