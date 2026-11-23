# Expedition 33: Clair Obscur - Coop (v2)

Para os que vêm depois, com seus amigos!

![](./docs/header_s.jpg)

[Read in English](./README.md)

Este é um fork do [Kouzukii/expedition33-coop](https://github.com/Kouzukii/expedition33-coop). Ele mantém os arquivos do
mod original sem alteração e acrescenta um mod Lua para o [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS), o
`E33CoopV2`, que corrige vários problemas do co-op e adiciona configurações por personagem. Testado com o jogo na
versão 1.5, os arquivos da v0.9.6 do mod original e uma build de desenvolvimento do UE4SS de outubro de 2026.

## Como funciona

- Nas batalhas, cada jogador controla os próprios personagens, inclusive aparar golpes e escolher ações.
- Na exploração, o Jogador 1 controla por padrão, mas qualquer jogador pode assumir apertando START (útil para subir
  de nível e escolher o equipamento dos seus personagens).

### Jogando com amigos pela internet

A Steam só oferece o "Remote Play Together" para jogos com co-op nativo, mas dá para usar o
[RemotePlayWhatever](https://github.com/m4dEngi/RemotePlayWhatever) para contornar isso.

## O que muda em relação ao mod original

O mod original é um conjunto de arquivos do Unreal (`expedition33_coop_P.pak/.ucas/.utoc`). Este fork usa esses
arquivos como estão e acrescenta um mod Lua do UE4SS por cima; nada nos arquivos originais é modificado.

### Configurações e batalhas

- **Os jogadores são escolhidos por personagem, não por posição no grupo.** No original, as Configurações têm
  "Character 1/2/3 Assignment", ligadas à posição no grupo, então trocar a ordem do grupo ou uma batalha solo (por
  exemplo, a luta contra a Sirène só com a Maelle) passa o turno para o jogador errado. Aqui cada personagem lembra o
  seu jogador e o mantém ao trocar o grupo, em batalhas solo e no time reserva. Depois que qualquer escolha é salva,
  os personagens sem jogador definido ficam com o Jogador 1.
- **Opção `Random (P1/P2)`.** Cada personagem com essa opção sorteia o jogador no começo de cada batalha e mantém o
  mesmo sorteio quando você tenta de novo uma batalha perdida.
- **Aviso de turno.** A mensagem "Player N's Turn (Personagem)" aparece no começo de cada turno de jogador.
- **Indicação na tela do time.** A tela do time mostra `P1`/`P2`/`P3` ao lado de cada personagem.
- **START sem querer durante a batalha é bloqueado** (opcional), para um toque acidental não tomar o controle 0 no
  meio da luta. O START continua funcionando na exploração e nas telas de Vitória/Fuga.
- **Todo turno inimigo começa com o controle 0 de volta no Jogador 1**, para a defesa do mod base partir sempre do
  mesmo estado.

### Controle na exploração

- **Quem está explorando continua no controle** depois das batalhas, nas telas de Vitória/Fuga e ao trocar de mapa.
  No original, o controle podia voltar para o Jogador 1 depois de trocar de mapa.
- Se o controle desse jogador não voltar em até 10 segundos depois de trocar de mapa (por exemplo, se o controle foi
  desconectado), o controle volta para o Jogador 1 e um aviso é escrito no log.

### Controles, menus e diálogos para o Jogador 2/3

- **O Jogador 2/3 avança os diálogos com A.** No original, quando o Jogador 2 estava explorando, só o Jogador 1
  conseguia passar as falas.
- **O Jogador 2/3 fecha as telas cheias** que aparecem depois dos diálogos (subida de nível de amizade, novo ataque
  de gradiente etc.) com A.
- **O Jogador 2/3 responde às janelas de confirmação** com A (confirmar) e B (cancelar). As janelas de segurar para
  confirmar ainda precisam do Jogador 1.
- **O jogo fica no modo controle para o Jogador 2/3**: sem ícones de teclado aparecendo nos diálogos, e as correções
  de modo de entrada do mod nunca cancelam um botão apertado nos menus.

### Cursor do mouse

- **Acabou o cursor piscando no meio da tela** ao descansar numa Bandeira de Expedição ou abrir menus.
- O cursor fica sempre escondido enquanto o Jogador 2/3 controla o jogo e nos controles extras; o Jogador 1 mantém o
  comportamento normal do mouse no jogo.

### Arquivo de configuração

- As opções ficam em `ue4ss\Mods\E33CoopV2\config.json` (veja [Configuração](#configuração)). As escolhas por posição
  do save do mod original são importadas na primeira vez que o jogo abre.

## Instalação

São três partes: o mod co-op original, o UE4SS e o `E33CoopV2`.

1. **Mod co-op original**: baixe a versão mais recente do
   [Kouzukii/expedition33-coop](https://github.com/Kouzukii/expedition33-coop/releases) e extraia
   `expedition33_coop_P.pak/.ucas/.utoc` em `..\Expedition 33\Sandfall\Content\Paks\~mods` (crie a pasta `~mods` se
   ela não existir).
2. **UE4SS**: instale o [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS/releases) em
   `..\Expedition 33\Sandfall\Binaries\Win64\`. O jogo usa a Unreal Engine 5.4, que a antiga v3.0.1 estável (2024)
   pode não suportar: use a v4.0.0 ou mais nova. Este mod foi testado com uma build de desenvolvimento de outubro de
   2026 (commit `cdbc0b66`, que aparece como "v3.0.1 Beta" no `UE4SS.log`); a v4.0.0 em si ainda não foi testada.
3. **E33CoopV2**: baixe o `E33CoopV2-<versão>.zip` em
   [Releases](https://github.com/orezraey/expedition33-coop/releases) deste fork e copie a pasta
   `ue4ss\Mods\E33CoopV2` para `..\Expedition 33\Sandfall\Binaries\Win64\ue4ss\Mods\`. O mod é ativado pelo próprio
   `enabled.txt`.

   Ou rode o instalador a partir da pasta extraída. Ele copia os scripts, mantém o seu `config.json` e adiciona
   `E33CoopV2 : 1` ao `mods.txt`:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\Install-CoopV2.ps1 -GameDir "C:\Program Files (x86)\Steam\steamapps\common\Expedition 33"
   ```

   `-BasePakDir "<pasta com os expedition33_coop_P.* originais>"` também copia os arquivos do mod original para a
   `~mods`.

Para atualizar, substitua a pasta `Scripts` (ou rode o instalador de novo). O seu `config.json` é mantido.

## Configuração

O `..\Win64\ue4ss\Mods\E33CoopV2\config.json` é criado na primeira vez que o jogo abre. Os jogadores de cada
personagem são escolhidos no menu Configurações do jogo; as outras opções são editadas no arquivo.

```json
{
  "assignments": {
    "Frey": 0,
    "Lune": 1,
    "Maelle": 3
  },
  "blockStartInBattle": true,
  "debug": false,
  "hasPerCharacterAssignments": true,
  "legacySlots": [0, 1, 2],
  "showTurnToast": true,
  "version": 2
}
```

- `assignments`: jogador de cada personagem (`0` = Jogador 1, `1` = Jogador 2, `2` = Jogador 3, `3` = Random (P1/P2)).
- `blockStartInBattle`: impede que o START tome o controle 0 durante uma batalha.
- `showTurnToast`: mostra a mensagem "Player N's Turn (Personagem)".
- `debug`: escreve linhas detalhadas `[E33CoopV2] [DEBUG]` em `..\Win64\ue4ss\UE4SS.log`.
- `legacySlots`: a escolha por posição importada do save do mod original. Vale por posição no grupo até você salvar
  uma escolha nas Configurações; a partir daí cada personagem tem a própria entrada em `assignments`.

Os valores "Character 1/2/3 Assignment" de um save `Coop` existente são importados como `legacySlots`.

## Problemas

Se algo der errado, coloque `"debug": true` no `config.json`, repita o problema e abra uma issue com a descrição exata
e o `..\Win64\ue4ss\UE4SS.log` anexado.

### Problemas conhecidos

- Ações de segurar o botão nos menus (Aprender Habilidade, Melhorar Atributos, Subir Nível da Arma, janelas de segurar
  para confirmar) só funcionam com o Jogador 1, como no mod original.

## Para desenvolvedores

### E33CoopV2 (Lua)

O mod fica em `ue4ss/Mods/E33CoopV2/Scripts`:

| Módulo | Responsabilidade |
| --- | --- |
| `main.lua` | Registra os ganchos e liga os módulos |
| `roster.lua` | Personagens jogáveis (`Frey`/Gustave, `Lune`, `Maelle`, `Sciel`, `Monoco`, `Verso`) e constantes do jogo |
| `config.lua` | Escolhas por personagem no `config.json`, migração do save, sorteios e manter o sorteio ao tentar de novo |
| `ue.lua` | Chamadas seguras ao UE4SS: grupo e batalha, troca do usuário do controle 0, diálogos, telas cheias e janelas |
| `battle.lua` | Passa as escolhas por personagem para o `CoopConfig` do mod base a partir dos personagens que estão na batalha |
| `control.lua` | Dono do controle 0: volta do controle depois de batalhas e trocas de mapa, bloqueio do START, turno inimigo, telas de Vitória/Fuga |
| `gamepad.lua` | Modo controle para o Jogador 2/3, A/B em diálogos, telas cheias e janelas, cursor do mouse |
| `ui.lua` | Opções no menu Configurações e `P1`/`P2`/`P3` na tela do time |
| `hooks.lua` | Registro dos ganchos na thread do jogo, inclusive os de Blueprints carregados depois |

Rode os testes offline com qualquer interpretador Lua 5.4:

```powershell
lua tests\run_tests.lua
```

### Arquivos base (mod original)

Os arquivos do Unreal em `./Sandfall` e o `./Program.cs` não foram alterados em relação ao upstream `6038f67`. Para
gerar de novo, siga as instruções de build em [README.md](./README.md#base-assets-original-mod).

## Créditos

Mod original de [Kouzukii](https://github.com/Kouzukii/expedition33-coop). Licença MIT, veja [LICENSE](./LICENSE).
