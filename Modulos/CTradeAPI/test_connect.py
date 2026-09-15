from ctrader_open_api import Client, TcpProtocol
from ctrader_open_api.messages.OpenApiMessages_pb2 import (
    ProtoOAApplicationAuthReq,
    ProtoOAGetAccountListByAccessTokenReq,
)


CLIENT_ID = "38030_9Ue5qL7BS6CoQYcEnMT2MG0s2oQDbbd0Xi6PVpKva62wUEaKNE"
CLIENT_SECRET = "QkjPpf6STZAFhzSNhRLRrq4Da08OYNjXZPWz7Os7MAM4eTTo0c"
ACCESS_TOKEN = "COLOQUE_SEU_ACCESS_TOKEN"


# Conecta no ambiente DEMO
client = Client(
    "demo1.p.ctrader.com",
    5035,
    TcpProtocol
)


def connected(client):
    print("CONECTADO AO CTRADER")

    # 1. Autentica a aplicação
    request = ProtoOAApplicationAuthReq()
    request.clientId = CLIENT_ID
    request.clientSecret = CLIENT_SECRET

    deferred = client.send(request)

    deferred.addCallback(application_authenticated)


def application_authenticated(response):
    print("APLICAÇÃO AUTENTICADA")

    # 2. Solicita as contas vinculadas ao Access Token
    request = ProtoOAGetAccountListByAccessTokenReq()
    request.accessToken = ACCESS_TOKEN

    deferred = client.send(request)

    deferred.addCallback(accounts_received)


def accounts_received(response):
    print("\nCONTAS ENCONTRADAS:")

    for account_id in response.ctidTraderAccountId:
        print(f"Account ID: {account_id}")

    print("\nTESTE FINALIZADO COM SUCESSO!")

    client.stopService()


def disconnected(client, reason):
    print("DESCONECTADO")
    print(reason)


client.setConnectedCallback(connected)
client.setDisconnectedCallback(disconnected)

client.startService()