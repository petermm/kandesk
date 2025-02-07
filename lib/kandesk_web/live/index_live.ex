defmodule KandeskWeb.IndexLive do
  use KandeskWeb, :live_view
  alias Kandesk.Schema.{User, Board, BoardUser, Column, Task, Comment, Tag}
  alias Kandesk.Repo
  import Ecto.Query
  import Kandesk.Util
  import KandeskWeb.Gettext

  import KandeskWeb.Endpoint,
    only: [subscribe: 1, unsubscribe: 1, broadcast_from: 4, broadcast: 3]

  # require Logger #Logger.info "params: #{inspect params}"

  @boards_topic "boards"
  @access_error "Unauthorized access detected"

  def mount(params, session, socket) do
    case connected?(socket) do
      true -> connected_mount(params, session, socket)
      false -> {:ok, assign(socket, page: "loading")}
    end
  end

  def connected_mount(_params, %{"user_id" => user_id}, socket) do
    boards = get_user_boards(user_id)
    subscribe(@boards_topic)
    user = Repo.get(User, user_id)

    {:ok,
     assign(socket |> set_locale(user),
       page: "dashboard",
       user: user,
       changeset: nil,
       show_modal: nil,
       boards: boards,
       board: nil,
       columns: [],
       column_id: nil,
       edit_row: nil,
       edit_mode: nil,
       top_bottom: nil,
       scroll_count: 0,
       settings: %{tags_size: :large_tags}
     )}
  end

  def render(%{page: "loading"} = assigns) do
    ~L"""
    <div><%= gettext("The page is loading, please wait...") %></div>
    """
  end

  def render(%{page: page} = assigns) do
    Phoenix.View.render(KandeskWeb.LiveView, "page_" <> page <> ".html", assigns)
  end

  # ---------------
  # get_user_boards
  # ---------------
  def get_user_boards(user_id) do
    Repo.all(
      from b in Board,
        left_join: bu in BoardUser,
        on: bu.board_id == b.id and bu.user_id == ^user_id,
        where: b.creator_id == ^user_id or bu.user_id == ^user_id,
        select_merge: %{board_user: bu},
        order_by: [b.name, b.id]
    )
  end

  def get_columns(board_id) do
    columns =
      Repo.all(from(c in Column, where: [board_id: ^board_id], order_by: c.position))
      |> Repo.preload([{:tasks, from(t in Task, order_by: t.position)}])
  end

  ## ------------
  ## handle_event
  ## ------------
  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, show_modal: nil)}
  end

  def handle_event("show_modal", %{"modal" => "create_board" = modal}, socket) do
    {:noreply, assign(socket, show_modal: modal, changeset: Board.changeset(%Board{}, %{}))}
  end

  def handle_event("show_modal", %{"modal" => "create_column" = modal}, socket) do
    {:noreply, assign(socket, show_modal: modal, changeset: Column.changeset(%Column{}, %{}))}
  end

  def handle_event("show_modal", %{"modal" => "create_task" = modal} = params, socket) do
    %{"column_id" => column_id, "top_bottom" => top_bottom} = params

    {:noreply,
     assign(socket,
       show_modal: modal,
       changeset: Task.changeset(%Task{}, %{}),
       column_id: to_integer(column_id),
       top_bottom: top_bottom
     )}
  end

  def handle_event("show_modal", %{"modal" => "admin_tags" = modal}, socket) do
    board = socket.assigns.board

    {:noreply,
     assign(socket,
       show_modal: modal,
       changeset: Board.changeset(board, %{}),
       tags_order: board.tags
     )}
  end

  def handle_event("show_modal", %{"modal" => "share_board" = modal}, socket) do
    {:noreply,
     assign(socket,
       show_modal: modal,
       boardusers: get_boardusers(socket.assigns.board.id),
       edit_row: nil,
       searches: []
     )}
  end

  def handle_event("show_modal", %{"modal" => "board_content"}, socket) do
    {:noreply, assign(socket, show_modal: "export_content", column_id: nil)}
  end

  def handle_event("show_modal", %{"modal" => "column_content", "id" => id}, socket) do
    id = to_integer(id)
    unless Enum.find(socket.assigns.columns, &(&1.id == id)), do: raise(@access_error)

    {:noreply, assign(socket, show_modal: "export_content", column_id: id)}
  end

  ## ------
  ## boards
  ## ------
  def handle_event("create_board", %{"board" => form_data}, %{assigns: assigns} = socket) do
    case create_board(form_data, assigns) do
      {:ok, board} ->
        boards = get_user_boards(assigns.user.id)
        broadcast_from(self(), @boards_topic, "create_board", %{board: board, boards: boards})
        {:noreply, assign(socket, show_modal: nil, boards: boards)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  def create_board(form_data, assigns) do
    attrs = %{
      name: form_data["name"],
      descr: form_data["descr"],
      creator_id: assigns.user.id,
      token: Ecto.UUID.generate(),
      is_active: true,
      is_public: false,
      tags: [
        %{id: 0, color: "#7c1a9c", name: gettext("Version")},
        %{id: 1, color: "#c14bfb"},
        %{id: 2, color: "#ed207b", name: gettext("Critical")},
        %{id: 3, color: "#ff8318", name: gettext("Warning")},
        %{id: 4, color: "#edc30a", name: gettext("In progress")},
        %{id: 5, color: "#3ab54a", name: gettext("Done")},
        %{id: 6, color: "#93042d", name: gettext("Bug")},
        %{id: 7, color: "#c58994", name: gettext("Enhancement")},
        %{id: 8, color: "#9a7773", name: gettext("New feature")},
        %{id: 9, color: "#274c6d", name: gettext("Rejected")},
        %{id: 10, color: "#22a2d8", name: gettext("Needs feedback")},
        %{id: 11, color: "#53718b"}
      ]
    }

    %Board{}
    |> Board.changeset(attrs)
    |> Repo.insert()
  end

  def handle_event("edit_board", %{"id" => id}, %{assigns: assigns} = socket) do
    id = to_integer(id)
    row = Enum.find(assigns.boards, &(&1.id == id))
    unless user_rights(row, :edit_board?), do: raise(@access_error)

    changeset = Board.changeset(row, %{})
    {:noreply, assign(socket, changeset: changeset, show_modal: "edit_board", edit_row: row)}
  end

  def handle_event("update_board", %{"board" => form_data}, %{assigns: assigns} = socket) do
    row = assigns.edit_row
    unless %Board{} = row, do: raise(@access_error)

    case update_board(form_data, assigns) do
      {:ok, board} ->
        boards = get_user_boards(assigns.user.id)
        broadcast_from(self(), @boards_topic, "update_board", %{board: board})
        {:noreply, assign(socket, show_modal: nil, boards: boards)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  def update_board(form_data, assigns) do
    attrs = %{
      name: form_data["name"],
      descr: form_data["descr"]
    }

    assigns.edit_row
    |> Board.changeset(attrs)
    |> Repo.update()
  end

  def handle_event("delete_board", %{"id" => id}, %{assigns: assigns} = socket) do
    id = to_integer(id)
    row = Enum.find(assigns.boards, &(&1.id == id))
    unless user_rights(row, :delete_board?), do: raise(@access_error)

    {:ok, _} = Repo.query("select sp_delete_board($1);", [id])
    boards = for b <- assigns.boards, b.id != id, do: b
    broadcast_from(self(), @boards_topic, "delete_board", %{id: id})
    {:noreply, assign(socket, boards: boards)}
  end

  def handle_event("view_board", %{"id" => id}, %{assigns: assigns} = socket) do
    id = to_integer(id)
    board = Enum.find(assigns.boards, &(&1.id == id))
    unless board, do: raise(@access_error)

    # eventually unsubscribe previous board
    assigns.board && unsubscribe(assigns.board.token)
    columns = get_columns(id)
    subscribe(board.token)
    {:noreply, assign(socket, page: "board", board: board, columns: columns)}
  end

  def handle_event("view_dashboard", _params, %{assigns: assigns} = socket) do
    # eventually unsubscribe previous board
    assigns.board && unsubscribe(assigns.board.token)
    {:noreply, assign(socket, page: "dashboard")}
  end

  ## ----
  ## tags
  ## ----
  def handle_event("set_board_tags", params, %{assigns: assigns} = socket) do
    %{"board" => %{"tags" => tags}} = params
    unless user_rights(assigns.board, :admin_tags?), do: raise(@access_error)

    case update_tags(tags, assigns) do
      {:ok, board} ->
        bid = board.id
        boards = for b <- assigns.boards, do: if(b.id == bid, do: board, else: b)
        broadcast_from(self(), @boards_topic, "update_board", %{board: board})
        {:noreply, assign(socket, show_modal: nil, boards: boards, board: board)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  def update_tags(tags, assigns) do
    # sort by integer instead of string due to form conversion (case when > 9 tags)
    sorted_tags =
      Enum.map(tags, fn {k, v} -> {to_integer(k), v} end)
      |> Enum.sort(fn {k, _v}, {k1, _v1} -> k < k1 end)
      |> Enum.map(fn {_k, v} -> v end)

    assigns.board
    |> Board.changeset(%{tags: sorted_tags})
    |> Repo.update()
  end

  def handle_event("toggle_tags_size", _params, %{assigns: assigns} = socket) do
    settings =
      case assigns.settings do
        %{tags_size: :large_tags} = settings -> %{settings | tags_size: :small_tags}
        %{tags_size: :small_tags} = settings -> %{settings | tags_size: :large_tags}
      end

    {:noreply, assign(socket, settings: settings)}
  end

  def handle_event("add_tag", _params, %{assigns: assigns} = socket) do
    changeset = assigns.changeset
    unless user_rights(assigns.board, :admin_tags?), do: raise(@access_error)

    {id, tags} =
      case Ecto.Changeset.get_change(changeset, :tags) do
        nil ->
          tags = assigns.board.tags
          {length(tags), tags}

        changeset ->
          inserts = for c <- changeset, c.action === :insert, do: c
          {length(inserts), changeset}
      end

    changeset = Ecto.Changeset.put_change(changeset, :tags, tags ++ [%{id: id, color: "#666666"}])
    {:noreply, assign(socket, changeset: changeset, scroll_count: assigns.scroll_count + 1)}
  end

  def handle_event("move_tag", params, %{assigns: assigns} = socket) do
    %{"old_pos" => old_pos, "new_pos" => new_pos} = params
    unless user_rights(assigns.board, :admin_tags?), do: raise(@access_error)

    # due to form hidden fields
    old_pos = old_pos - 2
    new_pos = new_pos - 2

    tags =
      if new_pos > old_pos do
        {l1, lres} = Enum.split(assigns.tags_order, old_pos - 1)
        {moved_tag, lres} = List.pop_at(lres, 0)
        {l2, l3} = Enum.split(lres, new_pos - old_pos)
        l1 ++ l2 ++ [moved_tag] ++ l3
      else
        {l1, lres} = Enum.split(assigns.tags_order, new_pos - 1)
        {l2, lres} = Enum.split(lres, old_pos - new_pos)
        {moved_tag, l3} = List.pop_at(lres, 0)
        l1 ++ [moved_tag] ++ l2 ++ l3
      end

    changeset = Ecto.Changeset.put_change(assigns.changeset, :tags, tags)
    {:noreply, assign(socket, changeset: changeset, tags_order: tags)}
  end

  ## -----------
  ## share board
  ## -----------
  def get_boardusers(board_id) do
    Repo.all(
      from bu in BoardUser,
        join: u in User,
        on: u.id == bu.user_id,
        where: [board_id: ^board_id],
        order_by: [u.lastname, u.firstname, u.email]
    )
    |> Repo.preload(:user)
  end

  def handle_event("view_share", %{"id" => id}, %{assigns: assigns} = socket) do
    id = to_integer(id)
    row = Enum.find(assigns.boardusers, &(&1.user_id == id))
    unless row, do: raise(@access_error)

    {:noreply, assign(socket, edit_row: row)}
  end

  def handle_event("update_share", params, %{assigns: assigns} = socket) do
    row = assigns.edit_row
    unless %BoardUser{} = row, do: raise(@access_error)

    # when no chekboxes are selected
    form_data = params["boarduser"] || %{}

    case update_rights(form_data, assigns, row) do
      {:ok, boarduser} ->
        uid = row.user_id
        bid = row.board_id

        boardusers =
          for r <- assigns.boardusers,
              do: if(r.user_id == uid && r.board_id == bid, do: boarduser, else: r)

        {:noreply, assign(socket, boardusers: boardusers, edit_row: nil)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  def update_rights(form_data, _assigns, edit_row) do
    attrs =
      for right <- BoardUser.rights() do
        {right, form_data[Atom.to_string(right)]}
      end
      |> Map.new()

    edit_row
    |> BoardUser.changeset(attrs)
    |> Repo.update()
  end

  def handle_event("delete_share", %{"id" => id}, %{assigns: assigns} = socket) do
    %{boardusers: boardusers, edit_row: edit_row} = assigns
    id = to_integer(id)
    row = Enum.find(boardusers, &(&1.user_id == id))
    unless row, do: raise(@access_error)

    Repo.delete!(row)
    boardusers = for r <- boardusers, r.user_id != id, do: r
    edit_row = if edit_row && edit_row.user_id == id, do: nil, else: edit_row
    {:noreply, assign(socket, boardusers: boardusers, edit_row: edit_row)}
  end

  def handle_event("search_user", %{"value" => search}, socket) when byte_size(search) == 0 do
    {:noreply, assign(socket, searches: [])}
  end

  def handle_event("search_user", %{"value" => search}, %{assigns: assigns} = socket)
      when byte_size(search) <= 100 do
    board_id = assigns.board.id
    search = "#{search}%"

    users =
      Repo.all(
        from u in User,
          left_join: b in BoardUser,
          on: u.id == b.user_id and b.board_id == ^board_id,
          where:
            is_nil(b.user_id) and
              (ilike(u.firstname, ^search) or
                 ilike(u.lastname, ^search) or
                 ilike(u.email, ^search)),
          order_by: [u.lastname, u.firstname, u.email],
          limit: 10
      )

    {:noreply, assign(socket, searches: users)}
  end

  def handle_event("add_share", %{"id" => id}, %{assigns: assigns} = socket) do
    id = to_integer(id)
    board_id = assigns.board.id

    {:ok, _} =
      %BoardUser{}
      |> BoardUser.changeset(%{user_id: id, board_id: board_id})
      |> Repo.insert()

    # we need to get preload :user
    boardusers = get_boardusers(board_id)
    boarduser = Enum.find(boardusers, &(&1.user_id == id))
    {:noreply, assign(socket, searches: [], boardusers: boardusers, edit_row: boarduser)}
  end

  ## -------
  ## columns
  ## -------
  def handle_event("create_column", params, %{assigns: assigns} = socket) do
    %{"column" => form_data} = params
    unless user_rights(assigns.board, :create_column?), do: raise(@access_error)

    case create_column(form_data, assigns) do
      {:ok, column} ->
        columns = assigns.columns ++ [%{column | tasks: []}]
        broadcast_from(self(), assigns.board.token, "set_columns", %{columns: columns})
        {:noreply, assign(socket, show_modal: nil, columns: columns)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  def create_column(form_data, assigns) do
    attrs = %{
      name: form_data["name"],
      descr: form_data["descr"],
      position: length(assigns.columns) + 1,
      visibility: form_data["visibility"],
      creator_id: assigns.user.id,
      board_id: assigns.board.id
    }

    %Column{}
    |> Column.changeset(attrs)
    |> Repo.insert()
  end

  def handle_event("edit_column", %{"id" => id}, %{assigns: assigns} = socket) do
    id = to_integer(id)
    row = Enum.find(assigns.columns, &(&1.id == id))
    unless row && user_rights(assigns.board, :edit_column?), do: raise(@access_error)

    changeset = Column.changeset(row, %{})
    {:noreply, assign(socket, changeset: changeset, show_modal: "edit_column", edit_row: row)}
  end

  def handle_event("update_column", params, %{assigns: assigns} = socket) do
    %{"column" => form_data} = params
    row = assigns.edit_row
    unless %Column{} = row, do: raise(@access_error)

    case update_column(form_data, assigns) do
      {:ok, column} ->
        cid = row.id
        columns = for c <- assigns.columns, do: if(c.id == cid, do: column, else: c)
        broadcast_from(self(), assigns.board.token, "set_columns", %{columns: columns})
        {:noreply, assign(socket, show_modal: nil, columns: columns)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  def update_column(form_data, assigns) do
    attrs = %{
      name: form_data["name"],
      descr: form_data["descr"],
      visibility: form_data["visibility"]
    }

    assigns.edit_row
    |> Column.changeset(attrs)
    |> Repo.update()
  end

  def handle_event("move_column", params, %{assigns: assigns} = socket) do
    %{"old_pos" => old_pos, "new_pos" => new_pos} = params
    unless user_rights(assigns.board, :move_column?), do: raise(@access_error)

    {:ok, _} =
      Repo.query("select sp_move_column($1, $2, $3);", [assigns.board.id, old_pos, new_pos])

    columns =
      if new_pos > old_pos do
        {l1, lres} = Enum.split(assigns.columns, old_pos - 1)
        {moved_column, lres} = List.pop_at(lres, 0)
        {l2, l3} = Enum.split(lres, new_pos - old_pos)
        l1 ++ l2 ++ [moved_column] ++ l3
      else
        {l1, lres} = Enum.split(assigns.columns, new_pos - 1)
        {l2, lres} = Enum.split(lres, old_pos - new_pos)
        {moved_column, l3} = List.pop_at(lres, 0)
        l1 ++ [moved_column] ++ l2 ++ l3
      end

    broadcast_from(self(), assigns.board.token, "set_columns", %{columns: columns})
    {:noreply, assign(socket, columns: columns)}
  end

  def handle_event("delete_column", %{"id" => id}, %{assigns: assigns} = socket) do
    id = to_integer(id)
    row = Enum.find(assigns.columns, &(&1.id == id))
    unless row && user_rights(assigns.board, :delete_column?), do: raise(@access_error)

    {:ok, _} = Repo.query("select sp_delete_column($1);", [id])
    columns = for c <- assigns.columns, c.id != id, do: c
    broadcast_from(self(), assigns.board.token, "set_columns", %{columns: columns})
    {:noreply, assign(socket, columns: columns)}
  end

  def handle_event("duplicate_column", %{"id" => id}, %{assigns: assigns} = socket) do
    id = to_integer(id)
    row = Enum.find(assigns.columns, &(&1.id == id))
    unless row && user_rights(assigns.board, :create_column?), do: raise(@access_error)

    {:ok, _} = Repo.query("select sp_duplicate_column($1, $2);", [id, assigns.user.id])

    columns = get_columns(assigns.board.id)
    broadcast_from(self(), assigns.board.token, "set_columns", %{columns: columns})
    {:noreply, assign(socket, columns: columns)}
  end

  def handle_event("move_column_to_board", params, %{assigns: assigns} = socket) do
    %{"id" => id, "board_id" => board_id} = params
    id = to_integer(id)
    board_id = to_integer(board_id)
    row = Enum.find(assigns.columns, &(&1.id == id))
    row2 = Enum.find(assigns.boards, &(&1.id == board_id))
    unless row && row2 && user_rights(assigns.board, :move_column?), do: raise(@access_error)

    {:ok, _} = Repo.query("select sp_move_column_to_board($1, $2);", [id, board_id])
    columns = for c <- assigns.columns, c.id != id, do: c
    broadcast_from(self(), assigns.board.token, "set_columns", %{columns: columns})
    broadcast(row2.token, "set_columns", %{columns: get_columns(row2.id)})
    {:noreply, assign(socket, columns: columns)}
  end

  ## -----
  ## tasks
  ## -----
  def handle_event("create_task", %{"task" => form_data}, %{assigns: assigns} = socket) do
    cid = assigns.column_id
    row = Enum.find(assigns.columns, &(&1.id == cid))
    unless row && user_rights(assigns.board, :create_task?), do: raise(@access_error)

    case create_task(form_data, assigns, row) do
      {:ok, task} ->
        if assigns.top_bottom === "top" do
          send(
            self(),
            {"move_task",
             %{
               "task_id" => task.id,
               "old_col" => cid,
               "new_col" => cid,
               "old_pos" => task.position,
               "new_pos" => 1
             }}
          )

          # columns refresh is done only once by move_task
          {:noreply, assign(socket, show_modal: nil)}
        else
          columns =
            for c <- assigns.columns,
                do: if(c.id == cid, do: %{c | tasks: c.tasks ++ [task]}, else: c)

          broadcast_from(self(), assigns.board.token, "set_columns", %{columns: columns})
          {:noreply, assign(socket, show_modal: nil, columns: columns)}
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  def create_task(form_data, assigns, column) do
    attrs = %{
      name: form_data["name"],
      descr: form_data["descr"],
      # when none is selected
      tags: form_data["tags"] || [],
      position: length(column.tasks) + 1,
      is_active: true,
      creator_id: assigns.user.id,
      column_id: assigns.column_id
    }

    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
  end

  def handle_event("edit_task", %{"id" => id}, %{assigns: assigns} = socket) do
    id = to_integer(id)
    row = Enum.find(Enum.flat_map(assigns.columns, & &1.tasks), &(&1.id == id))
    unless row && user_rights(assigns.board, :edit_task?), do: raise(@access_error)

    changeset = Task.changeset(row, %{})
    {:noreply, assign(socket, changeset: changeset, show_modal: "edit_task", edit_row: row)}
  end

  def handle_event("update_task", %{"task" => form_data}, %{assigns: assigns} = socket) do
    row = assigns.edit_row
    unless %Task{} = row, do: raise(@access_error)

    case update_task(form_data, assigns, row) do
      {:ok, task} ->
        cid = row.column_id
        tid = row.id

        columns =
          for c <- assigns.columns,
              do:
                if(c.id == cid,
                  do: %{c | tasks: for(t <- c.tasks, do: if(t.id == tid, do: task, else: t))},
                  else: c
                )

        broadcast_from(self(), assigns.board.token, "set_columns", %{columns: columns})
        {:noreply, assign(socket, show_modal: nil, columns: columns)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  def update_task(form_data, _assigns, edit_row) do
    old_tags = edit_row.tags
    # when none is selected
    new_tags = form_data["tags"] || []

    ## optimization: avoid updating tags when none has changed
    attrs =
      if Enum.reduce(old_tags, "", &(&2 <> to_string(&1.id))) ===
           Enum.reduce(new_tags, "", &(&2 <> &1["id"])),
         do: %{name: form_data["name"], descr: form_data["descr"]},
         else: %{name: form_data["name"], descr: form_data["descr"], tags: new_tags}

    edit_row
    |> Task.changeset(attrs)
    |> Repo.update()
  end

  def handle_event("move_task", params, %{assigns: assigns} = socket) do
    %{
      "task_id" => task_id,
      "old_col" => old_col,
      "new_col" => new_col
    } = params

    id = to_integer(task_id)
    row = Enum.find(Enum.flat_map(assigns.columns, & &1.tasks), &(&1.id == id))
    col1 = Enum.find(assigns.columns, &(&1.id == old_col))
    col2 = Enum.find(assigns.columns, &(&1.id == new_col))

    unless row && col1 && col2 && user_rights(assigns.board, :move_task?),
      do: raise(@access_error)

    do_event("move_task", params, socket)
  end

  def do_event("move_task", params, %{assigns: assigns} = socket) do
    %{
      "task_id" => task_id,
      "old_col" => old_col,
      "new_col" => new_col,
      "old_pos" => old_pos,
      "new_pos" => new_pos
    } = params

    {:ok, _} =
      Repo.query("select sp_move_task($1, $2, $3, $4, $5);", [
        task_id,
        old_col,
        new_col,
        old_pos,
        new_pos
      ])

    columns = get_columns(assigns.board.id)
    broadcast_from(self(), assigns.board.token, "set_columns", %{columns: columns})
    {:noreply, assign(socket, columns: columns)}
  end

  def handle_event("delete_task", %{"id" => id}, %{assigns: assigns} = socket) do
    id = to_integer(id)
    row = Enum.find(Enum.flat_map(assigns.columns, & &1.tasks), &(&1.id == id))
    unless row && user_rights(assigns.board, :delete_task?), do: raise(@access_error)

    {:ok, _} = Repo.query("select sp_delete_task($1);", [id])
    columns = for c <- assigns.columns, do: %{c | tasks: for(t <- c.tasks, t.id != id, do: t)}
    broadcast_from(self(), assigns.board.token, "set_columns", %{columns: columns})
    {:noreply, assign(socket, columns: columns)}
  end

  ## --------------------------
  ## handle_info from broadcast
  ## --------------------------
  def handle_info(%{event: "set_columns", payload: state}, socket) do
    {:noreply, assign(socket, state)}
  end

  def handle_info(%{event: "create_board", payload: state}, %{assigns: assigns} = socket) do
    %{board: board, boards: boards} = state

    if assigns.user.id == board.creator_id,
      do: {:noreply, assign(socket, boards: boards)},
      else: {:noreply, socket}
  end

  def handle_info(%{event: "update_board", payload: state}, %{assigns: assigns} = socket) do
    %{board: %{id: id} = board} = state

    boards = for b <- assigns.boards, do: if(b.id == id, do: board, else: b)
    board1 = if assigns.page == "board" and assigns.board.id == id, do: board, else: assigns.board
    {:noreply, assign(socket, %{boards: boards, board: board1})}
  end

  def handle_info(%{event: "delete_board", payload: %{id: id}}, %{assigns: assigns} = socket) do
    boards = for b <- assigns.boards, b.id != id, do: b

    if assigns.page == "board" and assigns.board.id == id do
      unsubscribe(assigns.board.token)
      {:noreply, assign(socket, page: "dashboard", boards: boards)}
    else
      {:noreply, assign(socket, boards: boards)}
    end
  end

  ## -----------------------------------------
  ## handle_info from handle_event self() cast
  ## -----------------------------------------
  def handle_info({"move_task" = event, params}, socket), do: do_event(event, params, socket)

  ## ---------------
  ## page delegation
  ## ---------------
  def handle_event(event, %{"delegate" => delegate} = params, socket) do
    valid_delegates = ["Page.Account", "Page.Admin_users"]
    unless Enum.any?(valid_delegates, &(&1 == delegate)), do: raise(@access_error)
    module = String.to_existing_atom("Elixir.KandeskWeb." <> delegate)
    apply(module, :handle_event, [event, params, socket])
  end

  def handle_info({event, %{"delegate_event" => delegate} = params}, socket) do
    valid_delegates = ["Page.Account", "Page.Admin_users"]
    unless Enum.any?(valid_delegates, &(&1 == delegate)), do: raise(@access_error)
    module = String.to_existing_atom("Elixir.KandeskWeb." <> delegate)
    apply(module, :handle_event, [event, params, socket])
  end
end
