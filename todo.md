<!--
Name: Roadmap and Strategy
Description: Список задач и описание новых стратегий развертывания (Relay/Target).
-->

# TODO

- [x] Подготовить диаграмму для новых сценариев (отражено в AGENTS.md)

Я хочу сделать новую стратегию, в рамках которой разделить скрипт на два сценария.


## Первый сценарий, который сейчас реализован почти также.

This is a script for a remote server running AmneziaWG. It sends messages to the internet directly, not through an intermediary machine like 3x. The 3x service also runs there and provides full internet access. Additionally, Guard Home is running and configured as usual. Direct connections to these two VPN servers are established within the client settings. If there is an option to specify DNS, the DNS from Guard Home is used. This is the first scenario where all incoming connections arrive directly from the internet, and all outgoing connections go directly to the internet without internal proxying within the server.

## Второй сценарий

Describes the second work scenario. In the second scenario, a local proxy server is used, where port forwarding is configured for Amnesia, which is forwarded as port forwarding to the external server from section number one without any transformations, changes, or repackaging. X-Ray is also forwarded without any changes or repackaging. And there are two additional servers. This is its own separate Amnesia server, which also works without forwarding. Everything that comes in immediately goes to the internet. And there is its own 3x, which sends everything it receives directly to the internet. And there is its own AdGuard Home, which also sends whatever it receives directly to the internet, without using internal routing within the server. The goal of these transformations is to achieve greater flexibility because 3x will have a web interface to manage settings. 3x installation can be managed, and at the end of the script output, a command to install 3x will be issued, as there were certain problems with achieving a silent installation. Therefore, it is better not to make it silent, but to make it interactive within the script. Well, that's probably the simplest. And importantly, Amnesia should not run on the standard port. Currently, it runs on the standard port. And its settings should be maximally optimized and differ from the standard ones. So that the MTU is optimal and there is a difference in all settings from the standard ones regarding server parameters.


Сначала запускается второй сценарий (удаленный), в котором становятся известны IP-адреса и номера портов. Затем на другом сервере запускается первый сценарий, в котором в диалоге скрипт запрашивает IP-адрес удалённого сервера и порт удалённого сервера и настраивает проброс через себя на эти порты с либо таких же портов, если они свободные, либо с других портов, если они заняты. Соответственно, эта настройка проброски должна выполняться в конце, после того как будет установлена амнезия AdGuard 3X.

Отрази эти сценарии в описании архитектуры.
