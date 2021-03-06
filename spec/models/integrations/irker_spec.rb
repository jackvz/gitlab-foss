# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'timeout'
require 'json'

RSpec.describe Integrations::Irker do
  describe 'Validations' do
    context 'when integration is active' do
      before do
        subject.active = true
      end

      it { is_expected.to validate_presence_of(:recipients) }
    end

    context 'when integration is inactive' do
      before do
        subject.active = false
      end

      it { is_expected.not_to validate_presence_of(:recipients) }
    end
  end

  describe 'Execute' do
    let(:irker) { described_class.new }
    let(:user) { create(:user) }
    let(:project) { create(:project, :repository) }
    let(:sample_data) do
      Gitlab::DataBuilder::Push.build_sample(project, user)
    end

    let(:recipients) { '#commits irc://test.net/#test ftp://bad' }
    let(:colorize_messages) { '1' }

    before do
      @irker_server = TCPServer.new 'localhost', 0

      allow(Gitlab::CurrentSettings).to receive(:allow_local_requests_from_web_hooks_and_services?).and_return(true)
      allow(irker).to receive_messages(
        active: true,
        project: project,
        project_id: project.id,
        server_host: @irker_server.addr[2],
        server_port: @irker_server.addr[1],
        default_irc_uri: 'irc://chat.freenode.net/',
        recipients: recipients,
        colorize_messages: colorize_messages)

      irker.valid?
    end

    after do
      @irker_server.close
    end

    it 'sends valid JSON messages to an Irker listener', :sidekiq_might_not_need_inline do
      irker.execute(sample_data)

      conn = @irker_server.accept

      Timeout.timeout(5) do
        conn.each_line do |line|
          msg = Gitlab::Json.parse(line.chomp("\n"))
          expect(msg.keys).to match_array(%w(to privmsg))
          expect(msg['to']).to match_array(["irc://chat.freenode.net/#commits",
                                            "irc://test.net/#test"])
        end
      end
    ensure
      conn.close if conn
    end
  end
end
