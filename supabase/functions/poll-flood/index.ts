import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Points at the current AI_Model deployment on Render. This used to point
// at a defunct Cloud Run URL (flood-api-...run.app) from an earlier
// iteration of the backend -- verified the response shape below
// (status/alert_level/probability/live_metrics.*) still matches exactly
// what this function expects, no other changes needed.
const MODEL_URL = 'https://agos-ai-model.onrender.com/api/predict-flood'

const ALERT_MESSAGES = {
  ADVISORY: 'AGOS Alert: ADVISORY level reached...',
  WARNING:  'AGOS Alert: WARNING level reached...',
  CRITICAL: 'AGOS Alert: CRITICAL level reached. EVACUATE IMMEDIATELY.',
  NORMAL:   'AGOS Alert: Situation has returned to NORMAL.',
}

Deno.serve(async () => {
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  )

  // 1. Fetch prediction
  const res = await fetch(MODEL_URL)
  const data = await res.json()
  const currentAlert = data.alert_level

  // 2. Get last known alert level from DB
  const { data: last } = await supabase
    .from('flood_snapshots')
    .select('alert_key')
    .order('created_at', { ascending: false })
    .limit(1)
    .single()

  const prevAlert = last?.alert_key ?? null

  // 3. Send SMS if alert level changed
  if (prevAlert !== null && prevAlert !== currentAlert) {
    const message = ALERT_MESSAGES[currentAlert]
    await supabase.from('alerts').insert({
      type: currentAlert, message, sent_by: 'AGOS Auto-Alert'
    })
    // on-alert-change webhook handles SMS + push dispatch on this insert
  }

  // 4. Save snapshot
  const rainfall = data?.live_metrics?.rainfall_mm ?? 0

  await supabase.from('flood_snapshots').insert({
    alert_level: data.alert_level === 'CRITICAL' ? 3 : data.alert_level === 'WARNING' ? 2 : data.alert_level === 'ADVISORY' ? 1 : 0,
    alert_key:   currentAlert,
    probability: data.probability,
    rainfall_mm: rainfall,
    humidity:    data?.live_metrics?.humidity ?? null,
    wind_signal: data?.live_metrics?.wind_signal ?? null,
    status:      data.status ?? null,
  })

  return new Response('ok')
})