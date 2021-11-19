require 'rails_helper'

RSpec.describe Product, type: :model do
  let(:user) { FactoryBot.create(:user) }

  describe 'creating a product' do
    before do
      allow(S3Service).to receive(:file_exists).and_return(false)
      allow(ShopifyAPI::Product).to receive(:delete).and_return(true)
      allow(SyncElasticDocumentJob).to receive(:perform_later).and_return(true)
    end

    it 'can be created' do
      product = FactoryBot.create :product
      expect(product).to be_persisted
      expect(product.likes_count).to eq 0
      expect(product.reports.count).to eq 0
    end

    it 'can be created with auto categorization' do
      FactoryBot.create(:category_product_type)
      product = FactoryBot.create :product
      expect(product).to be_persisted
      expect(product.likes_count).to eq 0
      expect(product.reports.count).to eq 0
      expect(product.categories.count).to eq 1
    end

    it 'can created with nil values in design_id' do
      product = FactoryBot.create :product, design_id: nil
      expect(product).to be_persisted
    end

    it 'can created with nil values in shopify_product_id' do
      product = FactoryBot.create :product, shopify_product_id: nil
      expect(product).to be_persisted
      product2 = FactoryBot.create :product, shopify_product_id: nil
      expect(product2).to be_persisted
    end

    it 'can only create unique shopify_product_id' do
      product = FactoryBot.create :product, shopify_product_id: '123123'
      expect(product).to be_persisted
      expect do
        FactoryBot.create :product, shopify_product_id: '123123'
      end.to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'checks relevant methods' do
      product = FactoryBot.create :product
      expect(product.serialize_count([], [])).not_to be nil
      expect(product.serialize_multi_types).not_to be nil
      expect(product.shopify_mockup_medium_url).not_to be nil
      product.image_uuid = '123123123'
      expect(product.image_path).to eq('123123123-2.jpg')
      expect(product.mockup_path).to eq('123123123-4.jpg')
      product.update(product_type: 'T-Shirts')
      expect(product.serialize(true, [], [], [], [], nil, 1234)).not_to be nil
      expect(product.like_id_for_user(product.user)).to be nil
      expect(product.super_like_id_for_user(product.user)).to be nil

      expect(Product.not_reported.count).to eq 1
      expect(Product.not_sellable.count).to eq 0
      expect(Product.private_only.count).to eq 0

      product.set_private(true)
      expect(product.is_public).to eq false
      product.set_private(false)
      expect(product.is_public).to eq true
      expect(product.is_buyable).to eq true
      product.set_private(true) { true }
      expect(product.is_public).to eq false
      product.set_private(false)
      expect(product.is_public).to eq true

      expect(Product.sellable.count).to eq 1
      expect(Product.only_public.count).to eq 1
      expect(Product.recent.count).to eq 1
    end

    it 'can be created with holiday prices' do
      stub_const('CurrentPrice', HolidayPrice)
      product = FactoryBot.create :product
      expect(product).to be_persisted
      expect(product.likes_count).to eq 0
      expect(product.reports.count).to eq 0
    end

    it 'can be liked' do
      product = FactoryBot.create :product
      like = FactoryBot.create :like, user: user, product: product
      expect(like).to be_persisted
      expect(product.likes_count).to eq 1
    end

    it 'checks for restricted keywords' do
      FilteredKeyword.create keyword: 'pikachu', action_type: :auto_unlist_and_report
      product = FactoryBot.create :product, title: 'Pikachu shirt'
      expect(product).to be_persisted
      expect(Product.sellable.count).to eq(0)
      expect(Product.unlisted_only.count).to eq(1)
      expect(Product.deleted.count).to eq(0)
    end

    it 'checks for restricted keywords' do
      FilteredKeyword.create keyword: 'pikachu', action_type: :auto_delete_and_report
      product = FactoryBot.create :product, title: 'Pikachu shirt'
      expect(product).to be_persisted
      expect(Product.unscoped.last.metadata).to eq('hidden_reason' => 'filtered-keyword-auto-delete')
      expect(Product.sellable.count).to eq(0)
      expect(Product.unlisted_only.count).to eq(1)
      expect(Product.deleted.count).to eq(0)
      expect(Product.last.metadata).to eq('hidden_reason' => 'filtered-keyword-auto-delete')
    end
  end

  describe 'updating a product' do
    it 'should validate third_party_commission_rate' do
      expect { FactoryBot.create(:product, third_party_commission_type: 'not_known') }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect { FactoryBot.create(:product, third_party_commission_type: 'fixed', third_party_commission_value: -1) }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect { FactoryBot.create(:product, third_party_commission_type: 'percentage', third_party_commission_value: 101) }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect { FactoryBot.create(:product, third_party_commission_type: 'percentage', third_party_commission_value: -1) }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect { FactoryBot.create(:product, third_party_commission_type: 'percentage', third_party_commission_value: 25) }
        .not_to raise_error
      expect { FactoryBot.create(:product, third_party_commission_type: 'fixed', third_party_commission_value: 4) }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect { FactoryBot.create(:product, third_party_commission_type: 'fixed', third_party_commission_value: 2) }
        .not_to raise_error
      expect { FactoryBot.create(:product, third_party_commission_type: 'fixed') }
        .to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'should update analytics' do
      product = FactoryBot.create(:product)
      product.update_analytics(:product_view, 10)
      expect(product.all_analytics.strip).to eq '10 Views'
    end
  end

  describe 'filtering title of product' do
    before do
      allow(SyncElasticDocumentJob).to receive(:perform_later).and_return(true)
    end

    it 'contains T-Shirts' do
      product = FactoryBot.create(:product, title: 'Totally random tshirt')
      expect(product.filtered_title).to eq 'Totally random'
    end

    it 'contains T-Shirts in middle' do
      product = FactoryBot.create(:product, title: 'Totally random tshirt and other shit')
      expect(product.filtered_title).to eq product.title
    end

    it 'contains hooded sweatshirts' do
      product = FactoryBot.create(:product, title: 'Totally random hooded sweaTshirt')
      expect(product.filtered_title).to eq 'Totally random'
    end

    it 'contains only hooded sweatshirts' do
      product = FactoryBot.create(:product, title: 'hooded sweaTshirt')
      expect(product.filtered_title).to eq product.title
    end
  end

  describe '#elasticsearch' do
    it 'search for random title' do
      VCR.use_cassette('successful_elasticsearch_random_title_v1') do
        product = FactoryBot.create(:product,
                                     id: 678,
                                     title: 'random_title',
                                     description: 'n/a',
                                     product_type: 'T-Shirts',
                                     shopify_mockup_url: 'something',
                                     is_rts: false,
                                     user: FactoryBot.create(:user))
        expect(product).to be_persisted
        expect(Product.esearch('random_title').order_by_popularity.first).to eq(product)
      end
    end

    it 'search for random title with special characters' do
      VCR.use_cassette('successful_elasticsearch_random_title_v2') do
        product = FactoryBot.create(:product,
                                     id: 578,
                                     title: 'random_title',
                                     description: 'n/a',
                                     product_type: 'T-Shirts',
                                     shopify_mockup_url: 'something',
                                     shopify_product_id: '123123123',
                                     is_rts: false,
                                     user: FactoryBot.create(:user))
        expect(product).to be_persisted
        expect(Product.esearch('socialmisfit"').order_by_popularity.first).to eq(nil)
      end
    end

    it 'can\'t search for hidden products' do
      VCR.use_cassette('should_not_return_search_result_for_hidden_products') do
        product = FactoryBot.create(:product,
                                     id: 679,
                                     title: 'random_title',
                                     description: 'n/a',
                                     product_type: 'T-Shirts',
                                     shopify_mockup_url: 'something',
                                     shopify_product_id: '123123124',
                                     is_rts: false,
                                     user: FactoryBot.create(:user))
        expect(product).to be_persisted
        product.enable_visibility_settings :unlisted
        expect(Product.esearch('random_title').order_by_popularity.first).to eq(nil)
      end
      VCR.use_cassette('should_not_return_search_result_for_private_products') do
        product = FactoryBot.create(:product,
                                     id: 668,
                                     title: 'random_title',
                                     description: 'n/a',
                                     product_type: 'T-Shirts',
                                     shopify_mockup_url: 'something',
                                     shopify_product_id: '123123125',
                                     is_rts: false,
                                     user: FactoryBot.create(:user))
        expect(product).to be_persisted
        product.enable_visibility_settings :private
        expect(Product.esearch('random_title').order_by_popularity.first).to eq(nil)
      end
      VCR.use_cassette('should_not_return_search_result_for_deleted_products') do
        product = FactoryBot.create(:product,
                                     id: 648,
                                     title: 'random_title',
                                     description: 'n/a',
                                     product_type: 'T-Shirts',
                                     shopify_mockup_url: 'something',
                                     shopify_product_id: '123123127',
                                     is_rts: false,
                                     user: FactoryBot.create(:user))
        expect(product).to be_persisted
        product.enable_visibility_settings :deleted
        expect(Product.esearch('random_title').order_by_popularity.first).to eq(nil)
      end
      VCR.use_cassette('should_return_search_result_for_sellable_products') do
        product = FactoryBot.create(:product,
                                     id: 638_545_343,
                                     title: 'glsgsinrilgnelrginelbrhlvnlsnbrebguoerhguerh',
                                     description: 'n/a',
                                     product_type: 'T-Shirts',
                                     shopify_mockup_url: 'something',
                                     shopify_product_id: '123123218',
                                     is_rts: false,
                                     user: FactoryBot.create(:user, email: 'totally_random_y@rageon.com'))
        expect(product).to be_persisted
        product.enable_visibility_settings :sellable
        expect(Product.esearch('glsgsinrilgnelrginelbrhlvnlsnbrebguoerhguerh')
          .order_by_popularity.first)
          .not_to eq(nil)
      end
    end
  end

  describe '#from_shopify_product' do
    let(:shopify_data) do
      {
        id:           1,
        title:        'This is totally random Shirt',
        product_type: 'T-Shirts',
        body_html:    'Description',
        handle:       'shirt-1',
        tags:         'foo',
        images:       [double('image', id: nil, src: 'http://sample.image/src.png', variant_ids: nil)],
        variants:     [
          double('variant',
                 size: 'Small',
                 price: '24.99',
                 sku: 'ROCTS0000UMD',
                 id: 123_123_123,
                 image_id: nil,
                 option1: 'Small',
                 option2: 'Standard',
                 compare_at_price: nil,
                 position: 1,
                 weight: nil,
                 metafields: [
                  double('metafield',key: 'color',value: '#fff')
                ])
        ],
        options:      [
          double('option', name: 'color', value: 'red'),
          double('option', name: 'style', value: 'big')
        ]
      }
    end
    let(:shopify) { double('shopify product', shopify_data) }

    it 'populates new records' do
      VCR.use_cassette('successful_elasticsearch_tshirt_v1', record: :new_episodes) do
        product = FactoryBot.build :product

        product.from_shopify_product(shopify)
        product.save
        expect(product).to be_persisted
        expect(Product.esearch('totally random shirt').order_by_popularity.first).to eq(product)
      end
    end

    it 'populates existing records' do
      VCR.use_cassette('successful_elasticsearch_tshirt_v2', record: :new_episodes) do
        tag = FactoryBot.create :tag, name: 'foo'
        product = FactoryBot.create :product, id: 786, tags: [tag]

        product.from_shopify_product(shopify)
        product.save
        expect(product).to be_persisted
      end
    end
  end

  describe '#visibility_settings' do
    Visibility = Product::VisibilitySettings

    it 'checks if product is setting visibility correctly' do
      product = FactoryBot.create(:product,
                                   visibility_settings: Visibility.get_value(0, :private))
      expect(product.is_setting_enabled?(:private)).to eq(true)
      expect(product.is_buyable).to eq(true)
      expect(product.visibility_settings).to eq(Visibility.get_value(0, :private))
      product.enable_visibility_settings :sellable
      expect(product.is_buyable).to eq(true)
      expect(product.visibility_settings).to eq(Visibility.get_value(0, :sellable))
      product.enable_visibility_settings :private
      expect(product.visibility_settings).not_to eq(Visibility.get_value(0, :private, :sellable))
      product.enable_visibility_settings :private, :unlisted, :deleted
      expect(product.is_buyable).to eq(false)
      expect(product.visibility_settings).to eq(Visibility.get_value(0, :private, :unlisted, :deleted))
      expect(product.is_setting_enabled?(:sellable)).to be(false)
      product.enable_visibility_settings :sellable
      expect(product.visibility_settings).to eq(Visibility.get_value(0, :sellable))
      product.enable_visibility_settings :unlisted
      expect(product.is_buyable).to eq(true)
      expect(product.visibility_settings).to eq(Visibility.get_value(0, :unlisted))
      expect(product.is_setting_enabled?(:sellable)).to be(false)
      product.enable_visibility_settings :sellable
      product.enable_visibility_settings :deleted
      expect(product.is_buyable).to eq(false)
      expect(product.visibility_settings).to eq(Visibility.get_value(0, :deleted))
      expect(product.is_setting_enabled?(:sellable)).to be(false)

      product.disable_visibility_settings :sellable
      expect(product.is_setting_enabled?(:deleted)).to eq(true)
      product.disable_visibility_settings :private
      expect(product.is_setting_enabled?(:sellable)).to eq(true)
      product.disable_visibility_settings :private
      expect(product.is_setting_enabled?(:private)).to eq(false)
      product.disable_visibility_settings :unlisted
      expect(product.is_setting_enabled?(:sellable)).to eq(true)
      product.disable_visibility_settings :sellable
      product.disable_visibility_settings :private, :unlisted, :deleted
      expect(product.is_setting_enabled?(:sellable)).to eq(true)
      product.disable_visibility_settings :sellable
      expect(product.is_setting_enabled?(:deleted)).to eq(true)
      product.disable_visibility_settings :deleted
      expect(product.is_setting_enabled?(:sellable)).to eq(true)
    end

    it 'checks if product is using overriden is_private and is_semi_private' do
      product = FactoryBot.create(
        :product,
        visibility_settings: Visibility.get_value(0, :private)
      )
      expect(product.is_private).to eq(true)
      expect(product.is_setting_enabled?(:private)).to eq(true)
      expect(product[:is_private]).to eq(false)

      product = FactoryBot.create(
        :product,
        is_private: true,
        shopify_product_id: 'Random123'
      )
      expect(product.is_setting_enabled?(:private)).to eq(false)
    end

    it 'checks if import is working fine' do
      FactoryBot.create(:product, shopify_product_id: '121')
      FactoryBot.create(:product, is_private: true, shopify_product_id: '122')
      FactoryBot.create(:product, is_semi_private: true, shopify_product_id: '123')
      FactoryBot.create(:product, restore_token: '123123123', shopify_product_id: '124')
      FactoryBot.create(:product, deleted_at: Time.zone.now, shopify_product_id: '125')

      Product::VisibilitySettings.import_visibility_settings
      expect(Product.sellable.count).to eq(1)
      expect(Product.unlisted_and_above.count).to eq(2)
      expect(Product.private_and_above.count).to eq(4)
      expect(Product.deleted.count).to eq(1)
    end
  end
end
