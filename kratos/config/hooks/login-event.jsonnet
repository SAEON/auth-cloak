function(ctx) {
  identity_id: ctx.identity.id,
  schema_id: ctx.identity.schema_id,
  email: ctx.identity.traits.email,
  session_id: ctx.session.id,
  authenticated_at: ctx.session.authenticated_at,
  expires_at: ctx.session.expires_at,
}
