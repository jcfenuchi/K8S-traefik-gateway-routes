# Gateway Route Factory

English version: [README.md](README.md)

Chart Helm (`anubis-gateway`) que publica serviços com objetos `Ingress` padrão do Kubernetes, atendidos por qualquer Ingress controller (Traefik, NGINX...), com a opção de colocar o [Anubis](https://anubis.techaro.lol) na frente de cada serviço para barrar bots.

O objetivo é centralizar a publicação. Em vez de cada projeto escrever e manter os próprios manifests de rota, todos os serviços ficam numa lista só, no `values.yaml` deste chart. Publicar um serviço novo é acrescentar um item nessa lista e rodar `helm upgrade`.

## Por que centralizar

Sem este chart, cada projeto que quer um endereço público precisa escrever a própria rota, o Service para alcançar o backend, a NetworkPolicy e, se quiser proteção contra bots, o Deployment do Anubis com a configuração dele. São quatro ou cinco arquivos por projeto, copiados de um projeto para o outro, e cada cópia vai divergindo com o tempo.

Com o chart, o mesmo serviço vira isto:

```yaml
endpoints:
  - name: "sonarqube"
    hostname: "sonarqube.devops.example.com"
    externalIp: "10.0.0.10"
    port: 9000
```

A partir dessas quatro linhas o chart cria tudo o que o serviço precisa, sempre do mesmo jeito. Uma correção feita no chart vale para todos os serviços no próximo `helm upgrade`, e a lista no `values.yaml` mostra num lugar só tudo o que está publicado.

## Como uma requisição chega ao serviço

```mermaid
flowchart LR
    U["Usuário<br/>sonarqube.devops.example.com"] --> GW

    subgraph cluster["Cluster Kubernetes"]
        GW["Ingress controller<br/>(Traefik, porta 80/443)"] --> R["Ingress<br/>host: sonarqube..."]
        R --> S["Service<br/>anubis-sonarqube"]
        S --> A["Pod do Anubis<br/>desafio para navegadores"]
    end

    A --> B["SonarQube<br/>10.0.0.10:9000"]
```

1. O DNS de `sonarqube.devops.example.com` aponta para o Traefik.
2. O Traefik recebe a requisição e procura o Ingress cujo `host` bate com o endereço pedido.
3. O Ingress entrega a requisição ao Service do Anubis.
4. O Anubis decide se o cliente precisa resolver o desafio. Se não precisar, ou depois que ele resolver, a requisição segue para o SonarQube.

Com o Anubis desligado para um serviço, os passos 3 e 4 viram um só: o Ingress entrega direto ao Service do próprio serviço.

## DNS wildcard: publicar sem pedir DNS

O ideal é criar uma única entrada de DNS wildcard apontando para o Traefik do cluster:

```
*.devops.example.com    A    <IP do Traefik>
```

Com ela, qualquer nome terminado em `.devops.example.com` já chega ao Traefik, e é o Ingress que decide para onde cada nome vai. Publicar um serviço novo deixa de exigir um pedido de DNS: basta acrescentar o item em `endpoints`.

### Proxy reverso para VMs fora do cluster

O serviço publicado não precisa estar no Kubernetes. Uma aplicação que roda numa VM fora do cluster, num servidor físico ou em qualquer máquina da rede é publicada do mesmo jeito, só com o IP e a porta. Por exemplo, uma aplicação web numa VM em `10.0.0.85:9000`:

```yaml
endpoints:
  - name: "minha-app-web"
    hostname: "minha-app-web.devops.example.com"
    externalIp: "10.0.0.85"
    port: 9000
```

Depois do `helm upgrade`, o cluster passa a funcionar como proxy reverso para essa VM. Quem acessa `minha-app-web.devops.example.com` recebe a resposta da aplicação em `10.0.0.85:9000` sem saber o IP nem a porta dela. A VM não precisa ficar exposta para os usuários, e nela não se instala nada: nenhum agente, nenhuma configuração nova.

```mermaid
flowchart LR
    U["Usuário"] -->|"minha-app-web.devops.example.com"| D["DNS<br/>*.devops.example.com"]
    D -->|"IP do Traefik"| T

    subgraph cluster["Cluster Kubernetes"]
        T["Traefik<br/>(Ingress)"] --> A["Anubis<br/>(se ligado)"]
    end

    subgraph fora["Fora do cluster"]
        V["VM<br/>10.0.0.85:9000"]
    end

    A -->|"proxy reverso"| V
```

Quem abre a conexão com a VM é o Pod do Anubis ou, com o Anubis desligado, o próprio Traefik. Para funcionar, a rede precisa deixar o cluster chegar até a VM:

- os nós do cluster precisam ter rota até o IP da VM;
- o firewall da VM, e qualquer firewall no caminho, precisa aceitar conexões vindas dos nós do cluster na porta do serviço (`9000` no exemplo);
- dentro do cluster, a NetworkPolicy que o chart cria para o Anubis já libera a saída só para esse IP e essa porta.

Para testar a partir do cluster antes de publicar:

```bash
kubectl run teste-vm --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -sS -o /dev/null -w "%{http_code}\n" http://10.0.0.85:9000/
```

Se o comando responder um código HTTP (200, 302, 401...), o cluster alcança a VM. Se der timeout, o problema está na rota ou no firewall, e não no chart.

O wildcard também simplifica o HTTPS: um único certificado para `*.devops.example.com`, guardado num Secret TLS e indicado em `ingress.tlsSecretName`, cobre todos os serviços publicados.

## Por que Ingress e não a Gateway API

Todo Ingress controller lê `Ingress`, enquanto o suporte à Gateway API depende do controller e de como ele foi instalado. Muitos clusters já vêm com um controller gerenciado pela plataforma, cuja configuração não pode ser alterada para ligar a Gateway API. Gerando `Ingress` simples, o chart funciona em qualquer um deles.

O Ingress tem dois limites que moldam o chart:

- Um Ingress só aponta para Services do próprio namespace. Para um `target` em outro namespace sem Anubis, o chart cria o Ingress nesse namespace.
- O que vai além de host, caminho e TLS (entrypoints, middlewares, redirecionamentos) é anotação específica do controller (no Traefik, `traefik.ingress.kubernetes.io/...`), definida em `ingress.annotations` ou por endpoint em `ingressAnnotations`.

## Por que o Anubis

Serviços web publicados na internet recebem, além das pessoas, uma quantidade grande de robôs: crawlers que coletam conteúdo para treinar IA, scrapers e scanners. Serviços como GitLab e SonarQube sofrem mais, porque cada página é cara de gerar e um robô pede milhares delas por minuto. O resultado é lentidão ou queda para quem usa o serviço de verdade.

O Anubis fica entre o Traefik e o serviço e pede ao navegador que resolva um pequeno cálculo (uma prova de trabalho) antes de liberar o acesso. Para uma pessoa isso costuma levar menos de um segundo e acontece uma vez só: depois de resolvido, o navegador recebe um cookie e passa direto até o cookie vencer. Para um robô que abre milhares de conexões, repetir o cálculo em cada uma sai caro demais.

```mermaid
sequenceDiagram
    participant N as Navegador
    participant A as Anubis
    participant S as Serviço (ex.: GitLab)

    N->>A: GET / (primeira visita)
    A-->>N: página de desafio
    Note over N: resolve o cálculo<br/>(em geral, menos de 1 segundo)
    N->>A: envia a resposta
    A-->>N: cookie de acesso
    N->>A: GET / com o cookie
    A->>S: repassa a requisição
    S-->>N: página do GitLab

    Note over N,S: Até o cookie vencer, as próximas requisições<br/>vão direto ao serviço, sem desafio.
```

O desafio só aparece para quem se identifica como navegador. `curl`, `git`, o cliente do Docker, probes e a maioria das ferramentas de linha de comando passam direto pelas regras padrão do Anubis. Por isso ele pode ficar na frente de um GitLab sem atrapalhar `git clone` nem pipelines.

### Quando desligar o Anubis

O desafio depende de JavaScript no navegador. Desligue o Anubis nos serviços em que isso atrapalha:

| Serviço | Anubis? | Motivo |
|---|---|---|
| GitLab, SonarQube, sites e painéis usados por pessoas | Ligado | É onde os robôs causam mais estrago |
| API chamada só por outros sistemas | Desligado | Não há navegador para resolver o desafio, e o Anubis só adicionaria um salto a mais |
| Webhooks recebidos de fora | Desligado | Quem chama é um sistema, não uma pessoa |
| Serviço acessado só pela rede interna | Opcional | Se não há robôs de fora, não há o que barrar |

## Ligando e desligando o Anubis

`anubisDefaults.enabled` define o padrão para todos os endpoints, e cada endpoint pode sobrescrever com `anubis: true` ou `anubis: false`:

```yaml
anubisDefaults:
  enabled: true              # Anubis ligado para todos, por padrão

endpoints:
  # Usa o padrão: com Anubis
  - name: "gitlab"
    hostname: "gitlab.devops.example.com"
    externalIp: "10.0.0.20"
    port: 80

  # Exceção: publicado sem Anubis
  - name: "api-interna"
    hostname: "api.devops.example.com"
    externalIp: "10.0.0.40"
    port: 8080
    anubis: false
```

O que o chart cria em cada caso:

| | Com Anubis | Sem Anubis |
|---|---|---|
| `Ingress` | Aponta para o Service do Anubis | Aponta direto para o serviço |
| `Deployment`, `Service`, `ConfigMap` e `NetworkPolicy` do Anubis | Criados | Não criados |
| Serviço por IP (`externalIp`) | O Anubis fala direto com o IP | O chart cria um `Service` com `EndpointSlice` apontando para o IP, porque um Ingress só aponta para Services |
| Serviço do cluster (`target`) em outro namespace | O Anubis fala direto com o Service | O `Ingress` é criado no namespace do serviço, porque um Ingress só aponta para Services do próprio namespace |

Sem o Anubis, `target` precisa ser um Service do cluster no formato `http://<service>.<namespace>.svc.cluster.local:<porta>`. Qualquer outra URL faz o `helm upgrade` parar com uma mensagem explicando o formato.

## Pré-requisitos

- Um Ingress controller no cluster. A IngressClass dele vai em `ingress.className` (confira com `kubectl get ingressclass`); vazio, usa a IngressClass padrão do cluster.
- `networkPolicy.ingressControllerPodSelector` precisa bater com os labels dos Pods do controller (`kubectl get pods -A --show-labels`); senão a NetworkPolicy impede o controller de chegar ao Anubis.
- O Traefik precisa repassar o header `X-Real-IP`, o que ele faz por padrão. Sem esse header o Anubis responde com erro em vez do desafio.
- Recomendado: uma entrada de DNS wildcard (`*.devops.example.com`) apontando para o Traefik, como explicado em "DNS wildcard: publicar sem pedir DNS". Sem ela, cada `hostname` novo precisa de uma entrada de DNS própria.

Os recursos são criados no namespace de `namespaceOverride` (padrão `global-gateway`), mesmo que o `helm` receba outro com `-n`.

## Uso

### 1. Criar o namespace e a chave do Anubis (uma vez só)

A chave Ed25519 assina os cookies de desafio resolvido. Todos os endpoints usam a mesma Secret. Se nenhum endpoint usar o Anubis, este passo pode ser pulado.

```bash
kubectl create namespace global-gateway

# Gerar a chave de 32 bytes (64 caracteres hex)
openssl rand -hex 32

# Criar a Secret no Kubernetes
kubectl create secret generic anubis-key \
  -n global-gateway \
  --from-literal=private-key="<SUA_CHAVE_HEX_GERADA>"
```

### 2. Listar os serviços em `values.yaml`

```yaml
namespaceOverride: "global-gateway"

ingress:
  className: "traefik"       # vazio = IngressClass padrão do cluster
  tlsSecretName: ""          # opcional: Secret TLS, ex.: wildcard *.devops.example.com

endpoints:
  # Serviço fora do cluster (IP e porta)
  - name: "rag"
    hostname: "rag.devops.example.com"
    externalIp: "10.0.0.30"
    port: 3000

  # Serviço dentro do cluster (URL do Service)
  - name: "argocd"
    hostname: "argocd.devops.example.com"
    target: "http://argocd-server.argocd.svc.cluster.local:80"
```

#### Como montar o `target`

O `target` é o endereço interno do Service no cluster, e segue sempre o mesmo formato:

```
http://<nome-do-service>.<namespace>.svc.cluster.local:<porta>
```

Desmontando o exemplo do ArgoCD:

```
http://argocd-server.argocd.svc.cluster.local:80
       └─────┬─────┘ └─┬──┘ └───────┬───────┘ └┬┘
             │         │            │          └── porta do Service
             │         │            └── sufixo fixo, igual para todo Service
             │         └── namespace onde o Service está
             └── nome do Service
```

Outro exemplo: uma API chamada `minha-api`, no namespace `financeiro`, com o Service na porta `8080`:

```yaml
endpoints:
  - name: "minha-api"
    hostname: "minha-api.devops.example.com"
    #        http://<nome-do-service>.<namespace>.svc.cluster.local:<porta>
    target: "http://minha-api.financeiro.svc.cluster.local:8080"
```

Para descobrir o nome, o namespace e a porta de um Service, liste os Services do cluster. As colunas `NAMESPACE`, `NAME` e `PORT(S)` dão as três partes do `target`:

```bash
kubectl get svc -A
# NAMESPACE    NAME            TYPE        CLUSTER-IP     PORT(S)
# argocd       argocd-server   ClusterIP   10.96.12.34    80/TCP,443/TCP
# financeiro   minha-api       ClusterIP   10.96.56.78    8080/TCP
```

A porta é a do Service (a primeira em `PORT(S)`), não a do container. Se o Service tiver mais de uma porta, use a que responde HTTP.

### 3. Instalar ou atualizar

De dentro da pasta do chart:

```bash
helm upgrade --install anubis-gateway . \
  -n global-gateway \
  -f values.yaml
```

O script `create-dns-entry.sh` roda esse mesmo comando e depois mostra os Pods e as rotas. O nome é antigo: ele não cria entrada de DNS. Com o DNS wildcard, nenhuma entrada nova é necessária; sem ele, a entrada de cada hostname é criada fora do chart. O primeiro argumento é o namespace do release (padrão `global-gateway`):

```bash
./create-dns-entry.sh
```

Para publicar um serviço novo, acrescente um item em `endpoints` e rode o `helm upgrade` de novo.

## Uma réplica por serviço

Cada serviço com Anubis roda com exatamente um Pod do Anubis, e o chart não tem opção de réplicas. Sem um storage compartilhado, o Anubis guarda os desafios em memória. Com duas réplicas, um desafio emitido por um Pod e respondido para o outro falha, e o usuário vê erros intermitentes.

Quando o Pod reinicia, os desafios em andamento se perdem e quem estava no meio de um precisa resolver de novo. Os cookies de quem já passou continuam valendo, porque são assinados pela chave da Secret, que não muda.

Para ter mais de uma réplica, é preciso configurar o Anubis com um storage compartilhado (Valkey/Redis), o que este chart ainda não faz.

## Caminhos liberados sem desafio

`bypassPaths` lista caminhos que passam direto, sem desafio, como health checks e métricas. O padrão é `/health,/ready,/metrics`. Cada caminho libera ele mesmo e tudo abaixo dele (`/health` libera `/health/db`, mas não `/healthz`).

O chart transforma essa lista numa regra `ALLOW` no policy file do Anubis e importa, logo depois, as regras padrão do próprio Anubis. Como clientes que não se identificam como navegador já passam direto, o `bypassPaths` serve para quando um navegador, ou algo que se identifica como um, precisa acessar esses caminhos sem desafio.

## Configuração por endpoint

Cada item de `endpoints` pode substituir alguns valores de `anubisDefaults`:

```yaml
endpoints:
  - name: "app-especial"
    hostname: "app-especial.devops.example.com"
    externalIp: "10.0.0.50"
    port: 8080
    anubis: true                       # sobrescreve anubisDefaults.enabled
    path: "/"                          # prefixo de caminho da rota (padrão "/")
    tlsSecretName: "app-especial-tls"  # sobrescreve ingress.tlsSecretName
    ingressAnnotations:                # somadas a ingress.annotations
      traefik.ingress.kubernetes.io/router.entrypoints: websecure
    cookieExpirationTime: "2h"         # validade do cookie de desafio resolvido (padrão 30m)
    logLevel: "debug"                  # padrão info
    bypassPaths: "/health,/docs"       # substitui a lista padrão
    cookieDomain: "devops.example.com" # domínio do cookie (padrão: só o próprio hostname)
    resources:
      limits:
        cpu: 500m
        memory: 512Mi
```

Mudar o `bypassPaths` de um endpoint reinicia só o Pod daquele endpoint, para ele carregar o policy file novo.
