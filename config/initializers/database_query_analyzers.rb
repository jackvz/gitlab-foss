# frozen_string_literal: true

# Currently we register validator only for `dev` or `test` environment
Gitlab::Database::QueryAnalyzer.instance.hook!
Gitlab::Database::QueryAnalyzer.instance.all_analyzers.append(::Gitlab::Database::QueryAnalyzers::GitlabSchemasMetrics)

if Rails.env.test? || Gitlab::Utils.to_boolean(ENV['ENABLE_CROSS_DATABASE_MODIFICATION_DETECTION'], default: false)
  Gitlab::Database::QueryAnalyzer.instance.all_analyzers.append(::Gitlab::Database::QueryAnalyzers::PreventCrossDatabaseModification)
end

Gitlab::Application.configure do |config|
  config.middleware.use(Gitlab::Middleware::QueryAnalyzer)
end
