class Api::V1::CommentsController < Api::V1::BaseController
  skip_before_action :require_api_user, only: :index

  def index
    page = (params[:page] || 1).to_i
    per = 30
    per = 30 if per > 30 || per < 1
    page = 1 if page < 1
    offset = per * (page - 1)

    load_api_user
    product = Product.find_by(
      'id = ? OR shopify_product_id = ?',
      params[:product_id].to_i,
      params[:shopify_product_id].to_s
    )
    if product
      @comments = Comment.includes(:preload_user, :product)
                         .where(product_id: product.id)
                         .limit(per)
                         .offset(offset)
                         .order(id: :desc)

      if current_user
        user_ids = @comments.collect(&:user_id).uniq
        following_ids = fetch_following_ids(current_user, user_ids)
        current_user_id = current_user.id
      else
        following_ids = []
      end

      @comments = @comments.reverse

      comments = []
      @comments.each do |comment|
        next unless comment.product.present?

        comment_json = comment.serialize(following_ids)
        comment_json[:owner] = comment.product.user.serialize_min(following_ids)
        comments << comment_json
      end
      render(json: { current_user_id: current_user_id, comments: comments })
    else
      render(json: { comments: [] })
    end
  end

  def create
    product = Product.find_by(
      'id = ? OR shopify_product_id = ?',
      params[:product_id].to_i,
      params[:shopify_product_id].to_s
    )
    unless product.present?
      render_errors 'Product not found'
      return
    end
    @comment = current_user.comments.new(
      product_id: product.id,
      comment: params[:comment]
    )
    if params[:source] == 'web' && !verify_google_captcha(params[:response])
      render(json: { error: 'failed to verify captcha' }) && return
    end

    if @comment.save
      CommentActivityJob.perform_later @comment
      CommentTagActivityJob.perform_later @comment if @comment.comment.include? '@'
    else
      render_errors @comment.errors.full_messages
    end
  end

  def update
    @comment = current_user.comments.where(id: create_params[:id]).first

    if @comment.present?
      @comment.comment = create_params[:comment] if create_params.key? :comment
      @comment.save
      render json: {}, status: 200
    else
      render_error 'You dont have permission to update this comment'
    end
  end

  def destroy
    comment = current_user.comments.where(id: delete_params[:id]).first
    comment ||= Comment.find_by(
      'id = ? AND product_id IN (?)',
      delete_params[:id],
      current_user.products.map(&:id)
    )
    if comment
      comment.delay.destroy
      render json: {}, status: 200
    else
      render_error 'You dont have permission to update this comment'
    end
  end

  private

  def delete_params
    params.permit(
      :id
    )
  end

  def create_params
    params.permit(
      :id,
      :comment,
      :product_id
    )
  end
end
