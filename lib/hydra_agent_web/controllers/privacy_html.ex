defmodule HydraAgentWeb.PrivacyHTML do
  use HydraAgentWeb, :html

  alias HydraAgentWeb.PrivacyCopy

  embed_templates "privacy_html/*"

  def t(locale, key), do: PrivacyCopy.t(locale, key)

  def disclosure_value(nil, locale), do: t(locale, :not_published)
  def disclosure_value(value, _locale), do: value

  def provider_posture(locale, :local), do: t(locale, :local)
  def provider_posture(locale, :external), do: t(locale, :external)
  def provider_posture(locale, :test_only), do: t(locale, :test_only)
end
