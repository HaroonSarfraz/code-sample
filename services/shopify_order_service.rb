# Public: Service to handle creating order in shopify
# Used by CreateOrderService, params should be passed from there
class ShopifyOrderService
  attr_accessor :order, :error

  # Public: either verifies the paypal payment, or authorizes the card in
  # stripe (throwing an error if they fail), then creates an order in shopify
  # (again thowing an error on failure), then stores the shopify order id
  # with the images stored here and lastly performs the stripe charge if we
  # are using stripe
  def initialize(user, params)
    @params = params
    @user   = user
    @error  = nil
    @order  = nil
  end

  # Public: submits the order to shopify
  #
  # Raises 'Invalid Shopify Order' if there is an issue creating the order
  def perform
    @order = build_order
    return false if @error
    save_shopify_order(1)
  end

  protected

  def save_shopify_order(retries_left = 1)
    return true if @order.save
  rescue => e
    if retries_left.zero?
      Rails.logger.error '====> Order Error <===='
      Rails.logger.error @order.inspect
      Rails.logger.error @order.errors.inspect
      @error = e.to_s
      @order = nil
      return false
    end
    save_shopify_order(retries_left - 1)
  end

  private

  # Private: sets up the shopify order from @params
  # does not save the shopify order
  # Returns a ShopifyAPI::Order
  def build_order
    order                   = ShopifyAPI::Order.new
    order.line_items        = []
    order.note_attributes   = []
    order.note              = @params[:app_notes] if @params[:app_notes]
    order.source_identifier = 'API'
    order.tags              = ['API']
    order.tags << @params[:third_party_app] if @params[:third_party_app]
    order.tags.flatten!

    if @params[:white_labeling_enabled]
      order.note_attributes.push(name: 'whitelabel', value: 'true')
      order.tags << 'White Label'
    end

    # Since Shopify has now introduced a 100 CustomerAddress per Customer limit
    # and the Order API automatically creates CustomAddress records for addresses
    # used on an order with an associated customer we're forced to leave the ROC
    # account's Customer off of the order.
    if @params[:third_party_app].blank?
      order.email        = @user.email
      order.customer     = { email: @user.email }
      order.send_receipt = true
    end

    build_shipping_address(order)
    build_billing_address(order)
    total_weight = build_line_items(order)
    return if @error
    build_shipping_lines(order, total_weight)
    build_tax_lines(order)

    if @params.key? :discount_codes
      order.discount_codes  = @params[:discount_codes]
      order.total_discounts = order.discount_codes.map { |dc| dc[:amount].to_f }.sum
    elsif @params[:third_party_app]
      total_price = @params[:total_price].to_f
      calculated_price = @params[:line_items].map do |line_item|
        Variant.where(shopify_variant_id: line_item[:variant_id]).first.price.to_f * line_item[:quantity].to_i
      end.sum
      calculated_price += @params[:shipping_line][:price].to_f
      order.total_discounts = [calculated_price - total_price, 0].max
    end

    order
  end

  def build_billing_address(order)
    return unless @params[:billing_address].present?
    order.billing_address = {
      address1: @params[:billing_address][:address1],
      address2: @params[:billing_address][:address2] || '',
      city: @params[:billing_address][:city],
      phone: @params[:billing_address][:phone],
      province: @params[:billing_address][:state] || @params[:billing_address][:province],
      zip: @params[:billing_address][:zip],
      country: @params[:billing_address][:country],
      name: @params[:billing_address][:name]
    }
  end

  def build_shipping_address(order)
    order.shipping_address = {
      address1: @params[:shipping_address][:address1],
      address2: @params[:shipping_address][:address2] || '',
      city: @params[:shipping_address][:city],
      phone: @params[:shipping_address][:phone],
      province: @params[:shipping_address][:state] || @params[:shipping_address][:province],
      zip: @params[:shipping_address][:zip],
      country: @params[:shipping_address][:country],
      first_name: @params[:shipping_address][:first_name],
      last_name: @params[:shipping_address][:last_name]
    }
  end

  def build_shipping_lines(order, total_weight)
    order.total_weight   = total_weight
    order.shipping_lines = [{
      code: @params[:shipping_line][:title],
      price: @params[:shipping_line][:price],
      title: @params[:shipping_line][:title],
      source: 'shopify'
    }]
  end

  def build_tax_lines(order)
    order.total_tax = @params[:total_tax]
    order.tax_lines = [{
      price: @params[:tax_line][:price],
      rate: @params[:tax_line][:rate],
      title: @params[:tax_line][:title]
    }]
  end

  def build_line_items(order)
    total_weight = 0.0
    @params[:line_items].each do |line_item|
      product = ShopifyAPI::Product.find(line_item[:product_id])
      images  = @user.images.where(uuid: line_item[:uuid])

      grams, sku = build_variants(line_item, product, total_weight)

      line_item_data = {
        product_id: product.id,
        variant_id: line_item[:variant_id],
        quantity: line_item[:quantity].to_i,
        grams: grams,
        sku: sku
      }

      line_item_data[:properties] = build_metafields(product, line_item, images)
      db_product = Product.includes(:user).find_by(shopify_product_id: product.id)
      rom_white_labeling_enabled = db_product && db_product.user && db_product.user.white_labeling_enabled
      roc_white_labeling_enabled = @params[:white_labeling_enabled] == true
      line_item_data[:properties] << {
        name: 'whitelabel',
        value: rom_white_labeling_enabled || roc_white_labeling_enabled ? 'true' : 'false'
      }
      order.line_items.push(line_item_data)
    end

    total_weight
  end

  def build_metafields(product, line_item, images)
    @uuid = nil
    metafields = build_product_metafields(product)
    if metafields.count < 2
      return build_image_metafields(line_item, images) if images.count.positive?
      generated_metafields = build_metafields_from_line_item(line_item)
      metafields = generated_metafields if generated_metafields.count > metafields.count
    end
    metafields
  end

  # Handles custom order using V2 or earlier [iOS & Web]
  def build_image_metafields(line_item, images)
    base_url = "https://#{ENV["AWS_BUCKET"]}.s3.amazonaws.com/#{images.last.uuid}"
    metafields = [{ name: 'uuid', value: line_item[:uuid] ? line_item[:uuid][0..7] : @uuid }]
    images.each do |image|
      name = Mockup::REVERSE_IMAGE_TYPE[image.image_type]
      next unless name
      file_type = file_type_of(line_item, image.image_type)
      metafields << { name: name, value: "#{base_url}-#{image.image_type}.#{file_type}" }
    end
    metafields
  end

  # Handles custom order using V3 [iOS & Web]
  def build_metafields_from_line_item(line_item)
    metafields = [{ name: 'uuid', value: line_item[:uuid] ? line_item[:uuid][0..7] : @uuid }]
    (line_item['multi_mockups'] || []).each do |mockup|
      type = Mockup::TYPE_TO_METAFIELD_ASSET[mockup['mockup_type']]
      next unless type
      if mockup['builder_primary_image_asset_id']
        metafields << { name: type[:primary_image], value: mockup['builder_primary_image_asset_id'] }
        metafields << { name: type[:primary_url], value: ROShared.image_url(mockup['builder_primary_image_asset_id']) }
      end
      metafields << { name: type[:image], value: mockup['builder_output_asset_id'] }
      metafields << { name: type[:image_url], value: ROShared.image_url(mockup['builder_output_asset_id']) }
      metafields << { name: type[:mockup], value: mockup['mockup_asset_id'] }
      metafields << { name: type[:mockup_url], value: ROShared.large_image_url(mockup['mockup_asset_id']) }
    end
    metafields
  end

  def file_type_of(line_item, image_type)
    dash_6_file_mockup = Mockup::REVERSE_MOCKUP_TYPE[image_type]
    if dash_6_file_mockup && line_item['multi_mockups']
      mockup_data = line_item['multi_mockups'].detect { |mm| mm['mockup_type'] == dash_6_file_mockup }
      if mockup_data && mockup_data['metadata']
        contains_image = if mockup_data['metadata']['layers']
                           mockup_data['metadata']['layers'].detect { |l| l['type'] == 'image' }
                         else
                           false
                         end
        return 'png' unless contains_image
      end
    end
    'jpg'
  rescue => error
    Rails.logger.error 'File Type Of'
    Rails.logger.error error
    'jpg'
  end

  # Handles order on posted product all Versions [iOS only]
  def build_product_metafields(product)
    metafields = []
    product.metafields.each do |metafield|
      if metafield.key == 'uuid'
        @uuid = metafield.value[0..7]
        metafields << { name: 'uuid', value: @uuid }
      else
        # Products created before V3
        obj = Mockup::METAFIELD_KEY[metafield.key]
        if obj
          metafields << { name: obj[:mockup], value: product.images[obj[:index]].try(:src) }
          metafields << { name: (obj[:image] || metafield.key), value: metafield.value }
        else
          # Products created by V3
          data = Mockup::ASSET_METAFIELD_KEY[metafield.key]
          next unless data
          metafields << { name: metafield.key, value: metafield.value }
          metafields << { name: data[:url], value: ROShared.image_url(metafield.value, nil, h: data[:size], w: data[:size]) }
        end
      end
    end
    metafields
  end

  def build_variants(line_item, product, total_weight)
    # calculate weight for line item properly
    grams = 0
    sku   = ''
    product.variants.each do |variant|
      next unless variant.id.to_s == line_item[:variant_id].to_s
      grams        = variant.grams
      sku          = variant.sku
      total_weight += grams * line_item[:quantity].to_i
      break
    end

    [grams, sku]
  end
end
