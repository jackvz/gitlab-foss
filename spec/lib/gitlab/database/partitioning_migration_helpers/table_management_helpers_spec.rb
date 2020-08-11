# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gitlab::Database::PartitioningMigrationHelpers::TableManagementHelpers do
  include PartitioningHelpers
  include TriggerHelpers

  let(:migration) do
    ActiveRecord::Migration.new.extend(described_class)
  end

  let_it_be(:connection) { ActiveRecord::Base.connection }
  let(:source_table) { :audit_events }
  let(:partitioned_table) { '_test_migration_partitioned_table' }
  let(:function_name) { '_test_migration_function_name' }
  let(:trigger_name) { '_test_migration_trigger_name' }
  let(:partition_column) { 'created_at' }
  let(:min_date) { Date.new(2019, 12) }
  let(:max_date) { Date.new(2020, 3) }

  before do
    allow(migration).to receive(:puts)
    allow(migration).to receive(:transaction_open?).and_return(false)
    allow(migration).to receive(:make_partitioned_table_name).and_return(partitioned_table)
    allow(migration).to receive(:make_sync_function_name).and_return(function_name)
    allow(migration).to receive(:make_sync_trigger_name).and_return(trigger_name)
    allow(migration).to receive(:assert_table_is_allowed)
  end

  describe '#partition_table_by_date' do
    let(:partition_column) { 'created_at' }
    let(:old_primary_key) { 'id' }
    let(:new_primary_key) { [old_primary_key, partition_column] }

    before do
      allow(migration).to receive(:queue_background_migration_jobs_by_range_at_intervals)
    end

    context 'when the table is not allowed' do
      let(:source_table) { :this_table_is_not_allowed }

      it 'raises an error' do
        expect(migration).to receive(:assert_table_is_allowed).with(source_table).and_call_original

        expect do
          migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date
        end.to raise_error(/#{source_table} is not allowed for use/)
      end
    end

    context 'when run inside a transaction block' do
      it 'raises an error' do
        expect(migration).to receive(:transaction_open?).and_return(true)

        expect do
          migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date
        end.to raise_error(/can not be run inside a transaction/)
      end
    end

    context 'when the the max_date is less than the min_date' do
      let(:max_date) { Time.utc(2019, 6) }

      it 'raises an error' do
        expect do
          migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date
        end.to raise_error(/max_date #{max_date} must be greater than min_date #{min_date}/)
      end
    end

    context 'when the max_date is equal to the min_date' do
      let(:max_date) { min_date }

      it 'raises an error' do
        expect do
          migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date
        end.to raise_error(/max_date #{max_date} must be greater than min_date #{min_date}/)
      end
    end

    context 'when the given table does not have a primary key' do
      let(:source_table) { :_partitioning_migration_helper_test_table }
      let(:partition_column) { :some_field }

      it 'raises an error' do
        migration.create_table source_table, id: false do |t|
          t.integer :id
          t.datetime partition_column
        end

        expect do
          migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date
        end.to raise_error(/primary key not defined for #{source_table}/)
      end
    end

    context 'when an invalid partition column is given' do
      let(:partition_column) { :_this_is_not_real }

      it 'raises an error' do
        expect do
          migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date
        end.to raise_error(/partition column #{partition_column} does not exist/)
      end
    end

    describe 'constructing the partitioned table' do
      it 'creates a table partitioned by the proper column' do
        migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date

        expect(connection.table_exists?(partitioned_table)).to be(true)
        expect(connection.primary_key(partitioned_table)).to eq(new_primary_key)

        expect_table_partitioned_by(partitioned_table, [partition_column])
      end

      it 'changes the primary key datatype to bigint' do
        migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date

        pk_column = connection.columns(partitioned_table).find { |c| c.name == old_primary_key }

        expect(pk_column.sql_type).to eq('bigint')
      end

      context 'with a non-integer primary key datatype' do
        before do
          connection.create_table :another_example, id: false do |t|
            t.string :identifier, primary_key: true
            t.timestamp :created_at
          end
        end

        let(:source_table) { :another_example }
        let(:old_primary_key) { 'identifier' }

        it 'does not change the primary key datatype' do
          migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date

          original_pk_column = connection.columns(source_table).find { |c| c.name == old_primary_key }
          pk_column = connection.columns(partitioned_table).find { |c| c.name == old_primary_key }

          expect(pk_column).not_to be_nil
          expect(pk_column).to eq(original_pk_column)
        end
      end

      it 'removes the default from the primary key column' do
        migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date

        pk_column = connection.columns(partitioned_table).find { |c| c.name == old_primary_key }

        expect(pk_column.default_function).to be_nil
      end

      it 'creates the partitioned table with the same non-key columns' do
        migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date

        copied_columns = filter_columns_by_name(connection.columns(partitioned_table), new_primary_key)
        original_columns = filter_columns_by_name(connection.columns(source_table), new_primary_key)

        expect(copied_columns).to match_array(original_columns)
      end

      it 'creates a partition spanning over each month in the range given' do
        migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date

        expect_range_partitions_for(partitioned_table, {
          '000000' => ['MINVALUE', "'2019-12-01 00:00:00'"],
          '201912' => ["'2019-12-01 00:00:00'", "'2020-01-01 00:00:00'"],
          '202001' => ["'2020-01-01 00:00:00'", "'2020-02-01 00:00:00'"],
          '202002' => ["'2020-02-01 00:00:00'", "'2020-03-01 00:00:00'"],
          '202003' => ["'2020-03-01 00:00:00'", "'2020-04-01 00:00:00'"]
        })
      end

      context 'when min_date is not given' do
        let(:source_table) { :todos }

        context 'with records present already' do
          before do
            create(:todo, created_at: Date.parse('2019-11-05'))
          end

          it 'creates a partition spanning over each month from the first record' do
            migration.partition_table_by_date source_table, partition_column, max_date: max_date

            expect_range_partitions_for(partitioned_table, {
              '000000' => ['MINVALUE', "'2019-11-01 00:00:00'"],
              '201911' => ["'2019-11-01 00:00:00'", "'2019-12-01 00:00:00'"],
              '201912' => ["'2019-12-01 00:00:00'", "'2020-01-01 00:00:00'"],
              '202001' => ["'2020-01-01 00:00:00'", "'2020-02-01 00:00:00'"],
              '202002' => ["'2020-02-01 00:00:00'", "'2020-03-01 00:00:00'"],
              '202003' => ["'2020-03-01 00:00:00'", "'2020-04-01 00:00:00'"]
            })
          end
        end

        context 'without data' do
          it 'creates the catchall partition plus two actual partition' do
            migration.partition_table_by_date source_table, partition_column, max_date: max_date

            expect_range_partitions_for(partitioned_table, {
              '000000' => ['MINVALUE', "'2020-02-01 00:00:00'"],
              '202002' => ["'2020-02-01 00:00:00'", "'2020-03-01 00:00:00'"],
              '202003' => ["'2020-03-01 00:00:00'", "'2020-04-01 00:00:00'"]
            })
          end
        end
      end

      context 'when max_date is not given' do
        it 'creates partitions including the next month from today' do
          today = Date.new(2020, 5, 8)

          Timecop.freeze(today) do
            migration.partition_table_by_date source_table, partition_column, min_date: min_date

            expect_range_partitions_for(partitioned_table, {
              '000000' => ['MINVALUE', "'2019-12-01 00:00:00'"],
              '201912' => ["'2019-12-01 00:00:00'", "'2020-01-01 00:00:00'"],
              '202001' => ["'2020-01-01 00:00:00'", "'2020-02-01 00:00:00'"],
              '202002' => ["'2020-02-01 00:00:00'", "'2020-03-01 00:00:00'"],
              '202003' => ["'2020-03-01 00:00:00'", "'2020-04-01 00:00:00'"],
              '202004' => ["'2020-04-01 00:00:00'", "'2020-05-01 00:00:00'"],
              '202005' => ["'2020-05-01 00:00:00'", "'2020-06-01 00:00:00'"],
              '202006' => ["'2020-06-01 00:00:00'", "'2020-07-01 00:00:00'"]
            })
          end
        end
      end

      context 'without min_date, max_date' do
        it 'creates partitions for the current and next month' do
          current_date = Date.new(2020, 05, 22)
          Timecop.freeze(current_date.to_time) do
            migration.partition_table_by_date source_table, partition_column

            expect_range_partitions_for(partitioned_table, {
              '000000' => ['MINVALUE', "'2020-05-01 00:00:00'"],
              '202005' => ["'2020-05-01 00:00:00'", "'2020-06-01 00:00:00'"],
              '202006' => ["'2020-06-01 00:00:00'", "'2020-07-01 00:00:00'"]
            })
          end
        end
      end
    end

    describe 'keeping data in sync with the partitioned table' do
      let(:source_table) { :todos }
      let(:model) { Class.new(ActiveRecord::Base) }
      let(:timestamp) { Time.utc(2019, 12, 1, 12).round }

      before do
        model.primary_key = :id
        model.table_name = partitioned_table
      end

      it 'creates a trigger function on the original table' do
        expect_function_not_to_exist(function_name)
        expect_trigger_not_to_exist(source_table, trigger_name)

        migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date

        expect_function_to_exist(function_name)
        expect_valid_function_trigger(source_table, trigger_name, function_name, after: %w[delete insert update])
      end

      it 'syncs inserts to the partitioned tables' do
        migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date

        expect(model.count).to eq(0)

        first_todo = create(:todo, created_at: timestamp, updated_at: timestamp)
        second_todo = create(:todo, created_at: timestamp, updated_at: timestamp)

        expect(model.count).to eq(2)
        expect(model.find(first_todo.id).attributes).to eq(first_todo.attributes)
        expect(model.find(second_todo.id).attributes).to eq(second_todo.attributes)
      end

      it 'syncs updates to the partitioned tables' do
        migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date

        first_todo = create(:todo, :pending, commit_id: nil, created_at: timestamp, updated_at: timestamp)
        second_todo = create(:todo, created_at: timestamp, updated_at: timestamp)

        expect(model.count).to eq(2)

        first_copy = model.find(first_todo.id)
        second_copy = model.find(second_todo.id)

        expect(first_copy.attributes).to eq(first_todo.attributes)
        expect(second_copy.attributes).to eq(second_todo.attributes)

        first_todo.update(state_event: 'done', commit_id: 'abc123', updated_at: timestamp + 1.second)

        expect(model.count).to eq(2)
        expect(first_copy.reload.attributes).to eq(first_todo.attributes)
        expect(second_copy.reload.attributes).to eq(second_todo.attributes)
      end

      it 'syncs deletes to the partitioned tables' do
        migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date

        first_todo = create(:todo, created_at: timestamp, updated_at: timestamp)
        second_todo = create(:todo, created_at: timestamp, updated_at: timestamp)

        expect(model.count).to eq(2)

        first_todo.destroy

        expect(model.count).to eq(1)
        expect(model.find_by_id(first_todo.id)).to be_nil
        expect(model.find(second_todo.id).attributes).to eq(second_todo.attributes)
      end
    end
  end

  describe '#drop_partitioned_table_for' do
    let(:expected_tables) do
      %w[000000 201912 202001 202002].map { |suffix| "#{Gitlab::Database::DYNAMIC_PARTITIONS_SCHEMA}.#{partitioned_table}_#{suffix}" }.unshift(partitioned_table)
    end

    let(:migration_class) { 'Gitlab::Database::PartitioningMigrationHelpers::BackfillPartitionedTable' }

    context 'when the table is not allowed' do
      let(:source_table) { :this_table_is_not_allowed }

      it 'raises an error' do
        expect(migration).to receive(:assert_table_is_allowed).with(source_table).and_call_original

        expect do
          migration.drop_partitioned_table_for source_table
        end.to raise_error(/#{source_table} is not allowed for use/)
      end
    end

    it 'drops the trigger syncing to the partitioned table' do
      migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date

      expect_function_to_exist(function_name)
      expect_valid_function_trigger(source_table, trigger_name, function_name, after: %w[delete insert update])

      migration.drop_partitioned_table_for source_table

      expect_function_not_to_exist(function_name)
      expect_trigger_not_to_exist(source_table, trigger_name)
    end

    it 'drops the partitioned copy and all partitions' do
      migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date

      expected_tables.each do |table|
        expect(connection.table_exists?(table)).to be(true)
      end

      migration.drop_partitioned_table_for source_table

      expected_tables.each do |table|
        expect(connection.table_exists?(table)).to be(false)
      end
    end
  end

  describe '#enqueue_partitioning_data_migration' do
    context 'when the table is not allowed' do
      let(:source_table) { :this_table_is_not_allowed }

      it 'raises an error' do
        expect(migration).to receive(:assert_table_is_allowed).with(source_table).and_call_original

        expect do
          migration.enqueue_partitioning_data_migration source_table
        end.to raise_error(/#{source_table} is not allowed for use/)
      end
    end

    context 'when run inside a transaction block' do
      it 'raises an error' do
        expect(migration).to receive(:transaction_open?).and_return(true)

        expect do
          migration.enqueue_partitioning_data_migration source_table
        end.to raise_error(/can not be run inside a transaction/)
      end
    end

    context 'when records exist in the source table' do
      let(:source_table) { 'todos' }
      let(:migration_class) { '::Gitlab::Database::PartitioningMigrationHelpers::BackfillPartitionedTable' }
      let(:sub_batch_size) { described_class::SUB_BATCH_SIZE }
      let(:pause_seconds) { described_class::PAUSE_SECONDS }
      let!(:first_id) { create(:todo).id }
      let!(:second_id) { create(:todo).id }
      let!(:third_id) { create(:todo).id }

      before do
        stub_const("#{described_class.name}::BATCH_SIZE", 2)

        expect(migration).to receive(:queue_background_migration_jobs_by_range_at_intervals).and_call_original
      end

      it 'enqueues jobs to copy each batch of data' do
        migration.partition_table_by_date source_table, partition_column, min_date: min_date, max_date: max_date

        Sidekiq::Testing.fake! do
          migration.enqueue_partitioning_data_migration source_table

          expect(BackgroundMigrationWorker.jobs.size).to eq(2)

          first_job_arguments = [first_id, second_id, source_table, partitioned_table, 'id']
          expect(BackgroundMigrationWorker.jobs[0]['args']).to eq([migration_class, first_job_arguments])

          second_job_arguments = [third_id, third_id, source_table, partitioned_table, 'id']
          expect(BackgroundMigrationWorker.jobs[1]['args']).to eq([migration_class, second_job_arguments])
        end
      end
    end
  end

  describe '#cleanup_partitioning_data_migration' do
    context 'when the table is not allowed' do
      let(:source_table) { :this_table_is_not_allowed }

      it 'raises an error' do
        expect(migration).to receive(:assert_table_is_allowed).with(source_table).and_call_original

        expect do
          migration.cleanup_partitioning_data_migration source_table
        end.to raise_error(/#{source_table} is not allowed for use/)
      end
    end

    context 'when tracking records exist in the background_migration_jobs table' do
      let(:migration_class) { 'Gitlab::Database::PartitioningMigrationHelpers::BackfillPartitionedTable' }
      let!(:job1) { create(:background_migration_job, class_name: migration_class, arguments: [1, 10, source_table]) }
      let!(:job2) { create(:background_migration_job, class_name: migration_class, arguments: [11, 20, source_table]) }
      let!(:job3) { create(:background_migration_job, class_name: migration_class, arguments: [1, 10, 'other_table']) }

      it 'deletes those pertaining to the given table' do
        expect { migration.cleanup_partitioning_data_migration(source_table) }
          .to change { ::Gitlab::Database::BackgroundMigrationJob.count }.from(3).to(1)

        remaining_record = ::Gitlab::Database::BackgroundMigrationJob.first
        expect(remaining_record).to have_attributes(class_name: migration_class, arguments: [1, 10, 'other_table'])
      end
    end
  end

  describe '#create_hash_partitions' do
    before do
      connection.execute(<<~SQL)
        CREATE TABLE #{partitioned_table}
          (id serial not null, some_id integer not null, PRIMARY KEY (id, some_id))
          PARTITION BY HASH (some_id);
      SQL
    end

    it 'creates partitions for the full hash space (8 partitions)' do
      partitions = 8

      migration.create_hash_partitions(partitioned_table, partitions)

      (0..partitions - 1).each do |partition|
        partition_name = "#{partitioned_table}_#{"%01d" % partition}"
        expect_hash_partition_of(partition_name, partitioned_table, partitions, partition)
      end
    end

    it 'creates partitions for the full hash space (16 partitions)' do
      partitions = 16

      migration.create_hash_partitions(partitioned_table, partitions)

      (0..partitions - 1).each do |partition|
        partition_name = "#{partitioned_table}_#{"%02d" % partition}"
        expect_hash_partition_of(partition_name, partitioned_table, partitions, partition)
      end
    end
  end

  def filter_columns_by_name(columns, names)
    columns.reject { |c| names.include?(c.name) }
  end
end
