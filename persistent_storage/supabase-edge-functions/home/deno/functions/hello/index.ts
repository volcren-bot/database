// Follow the Deno setup guide to integrate its language server with your editor: https://deno.land/manual/getting_started/setup_your_environment

Deno.serve(async () => {
  return new Response(
    `"Hello from Edge Functions!"`,
    { headers: { "Content-Type": "application/json" } },
  )
})

// To invoke: curl 'http://localhost:<KONG_HTTP_PORT>/functions/v1/hello' --header 'Authorization: Bearer <anon/service_role API key>'
