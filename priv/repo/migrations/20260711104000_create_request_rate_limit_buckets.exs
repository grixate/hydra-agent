defmodule HydraAgent.Repo.Migrations.CreateRequestRateLimitBuckets do
  use Ecto.Migration

  def change do
    create table(:request_rate_limit_buckets) do
      add :scope, :string, null: false
      add :key_hash, :binary, null: false
      add :bucket_start, :utc_datetime_usec, null: false
      add :request_count, :integer, null: false, default: 1
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:request_rate_limit_buckets, [:scope, :key_hash, :bucket_start],
             name: :request_rate_limit_buckets_identity_index
           )

    create index(:request_rate_limit_buckets, [:expires_at])

    create constraint(:request_rate_limit_buckets, :request_rate_limit_positive_count,
             check: "request_count > 0"
           )
  end
end
