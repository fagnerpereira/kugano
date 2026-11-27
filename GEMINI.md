# Diretrizes do Projeto — Piano Studio (Rails + Solid)

## Stack e Infraestrutura

- Use **Ruby on Rails** com **Solid Queue** (via `ActiveJob`) para tarefas assíncronas. **Nunca** adicione `sidekiq` nem `redis`.
- Preserve 100% da fidelidade musical e estrutural de `@legacy/todo_no_piano_studio.html`, incluindo a música "Todo Nó" completa e o sistema de **4 Níveis Progressivos Conectados** (cada nível reaproveita a base do anterior sem obrigar o aluno a reaprender tudo do zero).
- Nunca remova comentários explicativos existentes (incluindo comentários padrão do Rails/Dockerfile), a menos que seja explicitamente solicitado. Mantenha-os em inglês e sinta-se livre para melhorá-los ou adicionar explicações claras e detalhadas no código alterado/criado (preferindo convenções RDoc/YARD em Ruby/Rails).

## Parser e Fidelidade de Partituras

- Arquivos `.musicxml`, `.xml`, `.mxl` e `.mid` devem ser processados de forma **100% determinística** (sem usar LLM para ler notas ou compassos).
- `.pdf` passa por conversão OMR (ex.: Audiveris) para gerar `.musicxml`/`.mxl` antes do parser.
- Áudio/YouTube passa por pipeline de separação/transcrição para gerar MIDI/MusicXML antes do parser.

## UI e Ergonomia (TDAH-friendly)

- Mantenha interface limpa, alto contraste nos modos Claro e Escuro, notação em cifras (`C, D, E, F, G, A, B`), zoom de partitura e Modo Foco sem poluição visual.
- Não refatore arquivos não relacionados sem solicitação explícita.

## Fluxo de Trabalho para Economizar Tokens

- Antes de escrever código grande, apresente um plano curto com os arquivos exatos que serão criados ou alterados e aguarde confirmação.
