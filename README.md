# DDS Inovação

Central Inteligente de Trabalho de Diogo Soares, publicada no GitHub Pages, com Supabase para banco, autenticação, arquivos e Edge Functions.

© Diogo Soares. Todos os direitos reservados.

## Configuração

1. Execute `supabase/migrations/001_dds_flow.sql` no Supabase.
2. Copie URL e chave publicável para `config.js`.
3. Cadastre `ANTHROPIC_API_KEY` nos Secrets das Edge Functions — nunca no GitHub.
4. Publique a função `ai-assistant`.
5. Ative GitHub Pages com GitHub Actions.

O arquivo `config.js` contém apenas informações públicas protegidas por RLS. Nenhuma chave secreta pode ser commitada.
