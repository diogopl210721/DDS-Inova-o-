import 'jsr:@supabase/functions-js/edge-runtime.d.ts'
import { createClient } from 'npm:@supabase/supabase-js@2'

const cors = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST,OPTIONS'}
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,'Content-Type':'application/json'}})

Deno.serve(async(req)=>{
  if(req.method==='OPTIONS') return new Response('ok',{headers:cors})
  if(req.method!=='POST') return json({error:'Método não permitido'},405)
  const auth=req.headers.get('Authorization'); if(!auth) return json({error:'Não autenticado'},401)
  const url=Deno.env.get('SUPABASE_URL')!; const publishable=JSON.parse(Deno.env.get('SUPABASE_PUBLISHABLE_KEYS')||'{}').default
  const sb=createClient(url,publishable,{global:{headers:{Authorization:auth}},db:{schema:'dds_flow'}})
  const {data:{user},error:userError}=await sb.auth.getUser(); if(userError||!user) return json({error:'Sessão inválida'},401)
  const key=Deno.env.get('ANTHROPIC_API_KEY'); if(!key) return json({error:'Claude não configurado'},503)
  const input=await req.json(); const kind=input.kind
  let system=''; let prompt=''
  if(kind==='quick_capture'){
    system=`Você é o extrator operacional do DDS Inovação. Converta o texto em uma proposta estruturada sem executar ações. Não invente dados. Retorne SOMENTE JSON válido com client_name_raw, external_code, title, description, category, status, priority, dependency, internal_contact_name, next_action, next_action_at, confidence e ambiguities. Status: new, in_progress, waiting_client, waiting_internal, need_follow_up, completed. Prioridades: low, medium, high, urgent. Datas ISO-8601. Hoje: ${new Date().toISOString()}.`
    prompt=String(input.text||'').slice(0,12000)
  }else if(kind==='copilot_query'){
    const [{data:demands},{data:contracts}]=await Promise.all([sb.from('demands').select('id,title,status,priority,next_action,next_action_at,external_code,clients(trade_name),internal_contacts(name)').neq('status','completed').limit(80),sb.from('contracts').select('id,contract_number,end_date,clients(trade_name)').eq('status','active').limit(50)])
    system='Você é a DDS IA, assistente operacional do DDS Inovação. Responda em pt-BR somente com base nos dados fornecidos. Diferencie fatos de sugestões, seja breve e não execute alterações.'
    prompt=`Pergunta: ${String(input.question||'').slice(0,2000)}\nDados: ${JSON.stringify({demands,contracts}).slice(0,30000)}`
  }else return json({error:'Tipo inválido'},400)
  const response=await fetch('https://api.anthropic.com/v1/messages',{method:'POST',headers:{'content-type':'application/json','x-api-key':key,'anthropic-version':'2023-06-01'},body:JSON.stringify({model:Deno.env.get('ANTHROPIC_MODEL')||'claude-sonnet-4-5',max_tokens:1200,system,messages:[{role:'user',content:prompt}]})})
  if(!response.ok) return json({error:'Falha ao consultar IA'},502)
  const result=await response.json(); const text=result.content?.[0]?.text||''
  if(kind==='quick_capture'){try{return json(JSON.parse(text.replace(/^```json\s*|\s*```$/g,'')))}catch{return json({error:'Resposta da IA inválida'},502)}}
  return json({answer:text})
})
