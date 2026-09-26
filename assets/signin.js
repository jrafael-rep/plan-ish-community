import { $, explain, header, notice, sb } from './app.js';

const next = new URLSearchParams(location.search).get('next') || 'conta.html';
// Só páginas deste site: um "next" para outro endereço seria um redirecionamento aberto.
const safeNext = /^[a-z]+\.html(\?[\w=&%.-]*)?$/i.test(next) ? next : 'conta.html';

const session = await header('entrar');
if (session) location.replace(safeNext);

$('form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const email = $('email').value.trim();
  const button = e.submitter; button.disabled = true;
  const redirect = new URL(safeNext, location.href).href;
  const { error } = await sb.auth.signInWithOtp({ email, options: { emailRedirectTo: redirect } });
  button.disabled = false;
  if (error) notice($('status'), explain(error), 'error');
  else notice($('status'), `Enviámos um link para ${email}. Abre-o neste telemóvel ou computador para entrar.`);
});
