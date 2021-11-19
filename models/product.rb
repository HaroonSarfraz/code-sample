require 'utilities/elastic_search_helpers'

class Product < ApplicationRecord
  include Analytics
  include CommissionValidatable
  include ::Product::VisibilitySettings
  include ::Product::CustomSearchable
  include ::Product::Scopes
  include ::TypeVariants
  include ::Product::Shopify
  include ::Product::Commission
  include ::Product::CustomPreloader
  include ::Product::AssetPath
  include ::Product::Serializers
  include ::Product::Options
  include ::Product::Prices
  include ::Product::IPChecker

  MULTI_TYPE_TITLE_REGEX = /((hoodies?)|(tank tops?)|(shirt)|(tees?)|((dtg )?((black )|(white ))?(wom[ae]n'?s? )?(hooded )?(t|(sweat))(-| )?shirts?)|(onesies?)|(jumpsuits?)|(bandanas?)|(duvet covers?)|(couch pillows?)|(pillows?)|(pillow cases?)|(shower curtains?)|(curtains?)|(leggings?)|(iphone cases?)|(phone cases?)|(galaxy cases?)|(sweatpants?)|(joggers?)|(yoga pants?)|(ankle socks?)|(crew socks?)|(knee(-| )?high socks?)|(socks)|(underwears?)|(crop tops?)|(tops)|((fleece )?blankets?)|(coffee mugs?)|(aprons?)|(towels?)|(yoga mats?)|(((board)|(swim) )shorts?)|(shorts)|(dress(es)?)|(canvas(es)?)|(((black)|(white) )?shoes?))$/i

  attr_accessor :mockup_uploaded

  acts_as_paranoid

  belongs_to :user, counter_cache: true
  belongs_to :mockup

  has_many :mockups, as: :parent
  has_many :images,  through: :mockups

  has_many :sales
  has_many :super_likes, dependent: :destroy
  has_many :micro_sales
  has_many :likes
  has_many :comments
  has_many :activities, dependent: :destroy
  has_many :variants
  has_many :product_tags
  has_many :product_types

  has_many :reports, class_name: 'ReportedProduct', foreign_key: :product_id, dependent: :destroy
  has_many :latest_comments, -> { recent }, class_name: 'Comment'
  has_many :tags, through: :product_tags

  validates :title,               presence: true
  validates :product_type,        presence: true
  validates :shopify_product_id,  uniqueness: { message: 'Product has already been taken' }, allow_nil: true
  validates :product_type,        inclusion: { in: PRODUCT_TYPE_VARIANTS.keys }

  has_many  :category_products
  has_many  :categories, through: :category_products

  accepts_nested_attributes_for :variants
  accepts_nested_attributes_for :product_types

  after_initialize  :set_defaults, unless: :persisted?
  after_create      :product_created

  after_save        :update_search

  def set_defaults
    return unless !visibility_settings || visibility_settings < 1
    self['visibility_settings'] = VisibilitySettings::DEFAULT_VALUE
  end

  def description
    return unless self[:description]
    Rails::Html::WhiteListSanitizer.new.sanitize(self[:description], tags: []).strip
  end

  def num_likes
    likes.size
  end

  def num_super_likes
    super_likes.size
  end

  def num_comments
    comments.size
  end

  def like_id_for_user(user)
    likes.where(user_id: user.id).pluck(:id).first
  end

  def super_like_id_for_user(user)
    super_likes.where(user_id: user.id).pluck(:id).first
  end

  def variants_prototype(builder_type=nil, variant_params={})
    variants = PRODUCT_TYPE_VARIANTS[product_type]
    if variant_params[:selected_sizes].present?
      variants = variants.select {|a| variant_params[:selected_sizes].include?(a[:option1])}
    end
    parsed_variants = []
    if variants.present? && variants.first.keys.include?('option3')
      variants.uniq{|v| v.values_at(:option1, :option2, :option3)}
    end
    variants.each do |variant|
      if variant_params[:selected_colors].present?
        variant_params[:selected_colors].each do |color|
          parsed_variants << get_duplicate_variant(variant, color)
        end
      else
        parsed_variants << get_duplicate_variant(variant)
      end
    end
    parsed_variants.each_with_index.map { |v, i| v[:position] = i+1 }
    if parsed_variants.present?
      parsed_variants.uniq!{|v| v.values_at(:option1, :option2, :option3)}
    end
    parsed_variants
  end

  def get_duplicate_variant(variant, color=nil)
    dup_variant = {}
    variant.keys.each {|k| dup_variant[k] = variant[k] }
    dup_variant[:option2] = variant[:option2] || "‎"
    if color
      dup_variant[:option3] = color[:hex]
      dup_variant[:metafields] = [{key: 'color', value: color[:name], value_type: 'string', namespace: 'rageon_ios_api'}]
    end
    dup_variant
  end

  def mockup_transform
    if preload_mockup.try(:metadata)
      if ['2', '3'].include?(preload_mockup.metadata['version'])
        return preload_mockup.metadata['transform']
      end
      return preload_mockup.metadata['layers'][0]['transform']
    end
    nil
  end

  def options(builder_type=nil, option3_needed=false)
    if builder_type == 'DTG'
      options = [{ name: 'Size'}, { name: 'Quality' }]
    else
      options = ProductConstants.options(product_type)
    end
    options << { name: 'Color' } if option3_needed
    options
  end

  def image_uuid=(val)
    self.mockup_path = "#{val}-4.jpg"
    self.image_path  = "#{val}-2.jpg"
  end

  def background_color
    # 'black' if product_type == 'DB T-Shirts'
    'white'
  end

  def filtered_title
    new_title = title.sub(MULTI_TYPE_TITLE_REGEX, '')
    return new_title.strip if new_title.present?
    title
  end

  # expire the product and make it unbuyable
  def expire(reason = :campaign_expired)
    # Disabled while we're doing site wide timers rather than campaigns.
    # mdata = metadata || {}
    # mdata[:hidden_reason] = ProductConstants::DELETE_REASONS[reason.to_sym]
    # enable_visibility_settings :viewable do
    #   self.expire_at = nil
    #   self.expired_at = Time.now.utc
    #   self.metadata = mdata
    #   true
    # end
    # ShopifyToggleProductSellabilityJob.perform_now(shopify_product_id, 'off', true)
  end

  def updated_product_type
    return 'Black T-Shirt' if product_type == 'DB T-Shirts'
    product_type
  end

  private

  def reset_products_count
    User.delay.reset_counters(user_id, :products) unless user_id
  end

  def product_created
    CreateCategoryProductJob.perform_later(id)
  end

  def update_search
    # SearchIndexObjectsJob.perform_later("products", id)
  end
end
