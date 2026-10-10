#define _POSIX_C_SOURCE 200809L
#include <libubus.h>
#include <libubox/blobmsg_json.h>
#include <libubox/uloop.h>
#include <uci.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <signal.h>

static struct ubus_context *bus;
static struct ubus_object object;
static const struct blobmsg_policy policy[]={
 {.name="modem_id",.type=BLOBMSG_TYPE_STRING},
 {.name="endpoint",.type=BLOBMSG_TYPE_STRING},
 {.name="number",.type=BLOBMSG_TYPE_STRING},
 {.name="digit",.type=BLOBMSG_TYPE_STRING},
 {.name="session_id",.type=BLOBMSG_TYPE_STRING},
 {.name="call_revision",.type=BLOBMSG_TYPE_INT64},
 {.name="https_origin",.type=BLOBMSG_TYPE_STRING},
 {.name="address",.type=BLOBMSG_TYPE_STRING},
 {.name="port",.type=BLOBMSG_TYPE_INT32},
 {.name="payload_type",.type=BLOBMSG_TYPE_INT32}
};
struct response { struct blob_buf *buffer; };
static void reply_cb(struct ubus_request *request,int type,struct blob_attr *message)
{
 struct response *response=request->priv;struct blob_attr *item;size_t remaining;(void)type;
 blob_for_each_attr(item,message,remaining)blobmsg_add_field(response->buffer,blobmsg_type(item),blobmsg_name(item),blobmsg_data(item),blobmsg_data_len(item));
}
static int proxy(struct ubus_context *context,struct ubus_object *obj,struct ubus_request_data *request,const char *method,struct blob_attr *message)
{
 struct blob_attr *args[10]={0};struct uci_context *uci=uci_alloc_context();struct uci_package *package=NULL;
 struct uci_element *element;struct blob_buf reply={0};struct response response={.buffer=&reply};
 char target[96]={0};uint32_t id;int count=0,result=UBUS_STATUS_INVALID_ARGUMENT;
 const char *selected=NULL;(void)obj;
 if(message){blobmsg_parse(policy,10,args,blob_data(message),blob_len(message));if(args[0])selected=blobmsg_get_string(args[0]);}
 blob_buf_init(&reply,0);
 void *list=blobmsg_open_array(&reply,"modems");
 if(uci && uci_load(uci,"qmodem_voip",&package)==UCI_OK){
  uci_foreach_element(&package->sections,element){
   struct uci_section *section=uci_to_section(element);
   const char *modem=uci_lookup_option_string(uci,section,"modem_id");
   char name[96];void *entry;
   if(strcmp(section->type,"modem") || !modem || strlen(section->e.name)>48)continue;
   snprintf(name,sizeof(name),"qmodem.voip.%s",section->e.name);
   entry=blobmsg_open_table(&reply,NULL);blobmsg_add_string(&reply,"modem_id",modem);blobmsg_add_string(&reply,"group",section->e.name);
   blobmsg_add_u8(&reply,"running",!ubus_lookup_id(context,name,&id));blobmsg_close_table(&reply,entry);
   if(selected && strcmp(selected,modem))continue;
   strcpy(target,name);count++;
  }
 }
 blobmsg_close_array(&reply,list);
 if(package)uci_unload(uci,package);
 if(uci)uci_free_context(uci);
 if(count!=1){
  if(!strcmp(method,"status")){
   blobmsg_add_string(&reply,"status",count ? "select_modem" : "no_modem");
   blobmsg_add_u8(&reply,"require_modem_id",1);result=0;
  }
 }else if(!ubus_lookup_id(context,target,&id))result=ubus_invoke(context,id,method,message,reply_cb,&response,35000);
 else result=UBUS_STATUS_NOT_FOUND;
 if(!result)ubus_send_reply(context,request,reply.head);
 blob_buf_free(&reply);return result;
}
#define METHOD(name) UBUS_METHOD(name,proxy,policy)
static const struct ubus_method methods[]={METHOD("status"),METHOD("capabilities"),METHOD("enable"),METHOD("disable"),METHOD("originate"),METHOD("answer"),METHOD("reject"),METHOD("hangup"),METHOD("send_dtmf"),METHOD("call_history"),METHOD("issue_media_token"),METHOD("issue_socket_session"),METHOD("attach_rtp"),METHOD("release_rtp")};
static struct ubus_object_type type=UBUS_OBJECT_TYPE("qmodem_voip",methods);
static void stop(int signal){(void)signal;uloop_end();}
int main(void){
 if(uloop_init())return 1;
 bus=ubus_connect(NULL);
 if(!bus)return 1;
 ubus_add_uloop(bus);
 object.name="qmodem_voip";object.type=&type;object.methods=methods;object.n_methods=sizeof(methods)/sizeof(methods[0]);
 if(ubus_add_object(bus,&object))return 1;
 signal(SIGTERM,stop);signal(SIGINT,stop);uloop_run();ubus_free(bus);uloop_done();return 0;
}
