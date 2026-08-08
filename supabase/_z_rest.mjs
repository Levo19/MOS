const URL='https://rzbzdeipbtqkzjqdchqk.supabase.co';
const K='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ6YnpkZWlwYnRxa3pqcWRjaHFrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA4NzYwMDQsImV4cCI6MjA5NjQ1MjAwNH0.MAlSdz_ugGUZoaU5st6dA_gb_x_IiUL0TXxH176kY9k';
const r = await fetch(`${URL}/rest/v1/rpc/promo_sugerencias`, {
  method:'POST',
  headers:{ apikey:K, Authorization:'Bearer '+K, 'Content-Type':'application/json', 'Content-Profile':'mos', 'Accept-Profile':'mos' },
  body: JSON.stringify({ p: { n: 6 } })
});
console.log(r.status, (await r.text()).slice(0,600));
