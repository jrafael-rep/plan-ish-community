import { $, el, explain, header, notice, rememberAppScheme, sb, show, signInLink } from './app.js';
import { APP_SCHEME } from './config.js';

const session = await header('');
const status = $('status');
const params = new URLSearchParams(location.search);
const request = params.get('pedido') ?? '';
// A app diz como voltar a ela: a normal (planish) ou a de teste (planishdev).
// Só estas duas; qualquer outra coisa volta para a normal.
const scheme = ['planish', 'planishdev'].includes(params.get('app') ?? '') ? params.get('app') : APP_SCHEME;
// E fica lembrada neste browser, para os botões "Abrir no Plan-ish" dos itinerários.
if (params.get('app')) rememberAppScheme(scheme);

if (!/^[0-9a-f-]{36}$/i.test(request)) {
  notice(status, 'Este link não tem um pedido de ligação. Abre-o a partir da app: Comunidade › Ligar à Comunidade.', 'error');
} else if (!session) {
  $('signin-link').href = signInLink(`ligar.html?pedido=${request}&app=${scheme}`);
  show($('signin'), true);
} else {
  const { data, error } = await sb.rpc('get_app_link_request', { p_request_id: request });
  const info = data?.[0];
  if (error || !info) {
    notice(status, error ? explain(error) : 'Este pedido expirou ou já foi usado. Volta a carregar em "Ligar à Comunidade" na app.', 'error');
  } else if (info.confirmed) {
    finish();
  } else {
    const { data: profile } = await sb.from('profiles').select('display_name').eq('id', session.user.id).maybeSingle();
    $('device').textContent = info.device_label;
    $('account').textContent = profile?.display_name ?? session.user.email;
    show($('confirm'), true);
    $('confirm-btn').addEventListener('click', async () => {
      $('confirm-btn').disabled = true;
      const { error: err } = await sb.rpc('confirm_app_link', { p_request_id: request });
      if (err) { $('confirm-btn').disabled = false; notice(status, explain(err), 'error'); return; }
      show($('confirm'), false);
      finish();
    });
  }
}

function finish() {
  // Um toque da pessoa: o Chrome não abre a app por um redirecionamento automático.
  $('back').href = `${scheme}://community-linked?pedido=${encodeURIComponent(request)}`;
  show($('done'), true);
  status.replaceChildren(el('span'));
}
