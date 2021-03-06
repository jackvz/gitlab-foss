# frozen_string_literal: true
require 'spec_helper'

RSpec.describe Packages::Pypi::Metadatum, type: :model do
  describe 'relationships' do
    it { is_expected.to belong_to(:package) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:package) }
    it { is_expected.to allow_value('').for(:required_python) }
    it { is_expected.not_to allow_value(nil).for(:required_python) }
    it { is_expected.not_to allow_value('a' * 256).for(:required_python) }

    describe '#pypi_package_type' do
      it 'will not allow a package with a different package_type' do
        package = build('package')
        pypi_metadatum = build('pypi_metadatum', package: package)

        expect(pypi_metadatum).not_to be_valid
        expect(pypi_metadatum.errors.to_a).to include('Package type must be PyPi')
      end
    end
  end
end
