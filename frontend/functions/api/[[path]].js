// Cloudflare Pages Function: reenvía todo lo que llegue a /api/* al ALB de AWS (APISIX).
// Así el navegador solo habla con *.pages.dev y la cookie de sesión sigue funcionando.
export async function onRequest(context) {
  const url = new URL(context.request.url);
  const destino = context.env.API_ORIGIN + url.pathname + url.search;

  return fetch(destino, context.request);
}
