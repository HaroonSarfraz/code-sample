class Api::V1::ProductsController < Api::V1::BaseController
  skip_before_action :require_api_user, only: %i[public public_mockup public_meta get_multi_types popular_web update_position dtg_meta_colors]
  around_action :skip_bullet

  def skip_bullet
    Bullet.enable = false
    yield
  ensure
    Bullet.enable = true
  end

  def index
    if params[:id].present? || params[:spid].present?
      show
    else
      ips = IndexProductService.new(current_user, params, ios_build_number)
      ips.perform

      render(json: { products: ips.json_products, owner: ips.owner }) && return
    end
  end

  def show
    sps = ShowProductService.new(current_user, params, ios_build_number)
    sps.perform

    if sps.error
      render(
        json: { error: { message: 'Product Not Found!', info: 'Product Not Found!' } },
        status: :unprocessable_entity
      ) && return
    else
      render(json: { product: sps.json_product, owner: sps.owner }) && return
    end
  end

  def public
    @products = Product.only_public
                       .joins(:preload_user).includes(:preload_mockups)
                       .where(shopify_product_id: params[:shopify_product_ids])
                       .where('users.banned = false')
                       .email_confirmed
                       .limit(50)
    render(json: { products: @products.map(&:serialize_min), mockup_images: @images }) && return
  end

  def public_mockup
    @product = Product.only_public
                       .where(shopify_product_id: params[:shopify_product_id]).first
    unless @product
      @product = ProductType.where(shopify_product_id:  params[:shopify_product_id]).first
    end
    primary_image_asset_id = @product ? @product.primary_image_asset_id : nil
    render(json: { primary_image_asset_id: primary_image_asset_id }) && return
  end

  def public_meta
    @products = Product.only_public
                       .joins(:min_preload_user).where('users.banned = false')
                       .email_confirmed
                       .where(shopify_product_id: params[:spi])
                       .limit(50)
    render(json: { products: @products.map(&:serialize_count) }) && return
  end

  def authenticated_meta
    @products = Product.only_public.joins(:user).where('users.banned = false')
                       .email_confirmed
                       .where(shopify_product_id: params[:spi]).limit(50)
    # query to see if current user is following page owner. should return boolean
    product_ids = @products.collect(&:id).uniq
    like_ids = fetch_like_ids(current_user, product_ids)
    super_like_ids = fetch_super_like_ids(current_user, product_ids)
    following = Follow.where(follower_id: current_user.id, following_id: params[:following_id]).any?
    render(json: { products: @products.map { |p| p.serialize_count(like_ids, super_like_ids) }, following: following, current_user_id: current_user.id }) && return
  end

def dtg_meta_colors
  s_product = ShopifyAPI::Product.find(params[:spi])
  return unless s_product
  s_product.metafields
  if s_product.metafields
    s_metafield = s_product.metafields.detect { |m| m.key == 'colored_images' }
    colored_images = JSON.parse(s_metafield.value) if s_metafield
    render(json: { colored_images: colored_images }) && return
  end
  render(json: {}) && return
end

  def get_multi_types
    product = Product.only_public.joins(:user)
                     .includes(:preload_mockup, :preload_mockups, preload_product_types: :preload_mockups)
                     .where('users.banned = false')
                     .email_confirmed
                     .where(shopify_product_id: params[:shopify_product_id]).first
    if product
      render(json: { product: product.serialize_multi_types(current_user, params[:source]) }) && return
    else
      render(json: {}) && return
    end
  end

  def create
    cps = CreateProductFactory.get_service(current_user, params, ios_build_number)
    cps.perform

    if cps.error
      render_error cps.error
    else
      @product = cps.product
      render status: :created
    end
  end

  def update
    cps = UpdateProductService.new(current_user, params)
    cps.perform

    if cps.error
      render_error cps.error
    else
      render json: {}, status: 200
    end
  end

  def destroy
    dps = DestroyProductService.new(current_user, params)
    dps.perform

    render json: {}, status: 200
  end

  def top_brands
    ftbs = FetchTopBrandsService.new(current_user, params)
    ftbs.perform

    render(json: { brands: ftbs.json_brands, e_tag: ftbs.etag }) && return
  end

  def popular
    fpps = FetchPopularProductsService.new(current_user, params, ios_build_number)
    fpps.perform

    render(json: { products: fpps.json_products, e_tag: fpps.etag }) && return
  end

  def popular_web
    fpps = FetchPopularProductsService.new(current_user, params, ios_build_number)
    fpps.perform_web

    render(json: { products: fpps.json_products, e_tag: fpps.etag }) && return
  end

  def update_position
    p_params = position_update_params
    ids = p_params[:ids]
    positions = p_params[:positions]
    user_id = p_params[:user_id]
    sort = p_params[:sort]

    products_default = false

    if sort == 'newest'
      products_default = Product.where(user_id: user_id).order('created_at DESC')
    elsif sort == 'most-liked'
      products_default = Product.where(user_id: user_id).order('(likes_count + 3*super_likes_count + comments_count) DESC')
    elsif sort == 'best-selling'
      products_default = Product.where(user_id: user_id).order('sales_count DESC')
    else
      products_default = Product.where(user_id: user_id).order('position DESC')
    end

    count_default = if !sort || sort.length < 3
                      Product.where(user_id: user_id).count
                    else
                      products_default.count
                    end

    Product.transaction do
      products_default.each_with_index do |product, index|
        found = false
        ids.each_with_index do |x, i|
          if product.shopify_product_id == x
            found = true
            product.update(position: (count_default.to_i - positions[i].to_i))
          end
        end
        product.update(position: count_default.to_i - index.to_i) unless found
      end
    end
    render( json: {}, status: 200) && return
  end

  private

  def position_update_params
    params.permit(
      :user_id,
      :sort,
      ids: [],
      positions: []
    )
  end
end
