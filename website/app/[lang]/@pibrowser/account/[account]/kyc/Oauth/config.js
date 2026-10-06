// Konfigurasi provider OAuth2 generik (dengan PKCE). Isi lewat .env.
// Untuk Pi Network, ganti nilai *_URL sesuai dokumentasi resminya; nama
// provider ini hanya label, bukan jaminan kompatibilitas penuh.
export function oauthConfig(provider) {
  const name = process.env.OAUTH_PROVIDER_NAME || '';
  if (!name || provider !== name) return null;
  const required = [
    'OAUTH_CLIENT_ID', 'OAUTH_AUTHORIZE_URL', 'OAUTH_TOKEN_URL',
    'OAUTH_USERINFO_URL', 'OAUTH_REDIRECT_URI',
  ];
  for (const key of required) {
    if (!process.env[key]) return null;
  }
  return {
    provider: name,
    clientId: process.env.OAUTH_CLIENT_ID,
    clientSecret: process.env.OAUTH_CLIENT_SECRET || '',
    authorizeUrl: process.env.OAUTH_AUTHORIZE_URL,
    tokenUrl: process.env.OAUTH_TOKEN_URL,
    userinfoUrl: process.env.OAUTH_USERINFO_URL,
    redirectUri: process.env.OAUTH_REDIRECT_URI,
    scope: process.env.OAUTH_SCOPE || 'openid profile email',
  };
}
